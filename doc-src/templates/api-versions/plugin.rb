require 'json'
require_relative './model_documentor'

$APIS_DIR = File.expand_path(File.dirname(__FILE__) +
                             "/../../../vendor/apis/apis")
$API_FILE_MATCH = /(?:^|\/)([^\/-]+)-(\d+-\d+-\d+)\.json$/

YARD::Tags::Library.define_tag 'Service', :service
YARD::Tags::Library.define_tag 'Waiter Resource States', :waiter
YARD::Tags::Library.visible_tags << :waiter
YARD::Templates::Engine.register_template_path(File.dirname(__FILE__) + '/templates')

class YARD::CodeObjects::ClassObject
  def title
    path.gsub(/_(\d{4})(\d{2})(\d{2})/, ' (\1-\2-\3)')
  end

  def name(prefix = false)
    return super unless prefix
    @name.to_s.gsub(/_(\d{4})(\d{2})(\d{2})/, ' (\1-\2-\3)')
  end
end

module YARD::Registry
  class << self
    def register_aws(object)
      register_without_aws(object)
      ApiDocumentor.new(object).run if object.path == 'AWS'
    end
    alias register_without_aws register
    alias register register_aws
  end
end

class WaiterObject < YARD::CodeObjects::Base
  attr_accessor :operation

  def parameters; [] end
  def property_type; 'function' end
  def sep; '$waiter$' end
  def title; name.to_s end
end

class ApiDocumentor
  def initialize(root = :root)
    @root = root
  end

  def run
    build_map.each do |service, files|
      files.sort.each.with_index do |file, i|
        generate_api(file, !(i == files.length - 1))
      end
    end
  end

  def build_map
    map = {}
    Dir.entries($APIS_DIR).each do |file|
      if file =~ $API_FILE_MATCH
        (map[$1] ||= []).push(File.join($APIS_DIR, file))
      end
    end
    map
  end

  def generate_api(file, version_suffix = true)
    _, klass, version = *file.match($API_FILE_MATCH)
    identifier = klass.downcase
    name = version_suffix ? klass + '_' + version.gsub('-', '') : klass

    log.progress("Parsing AWS.#{klass} (#{version})")
    svc = YARD::CodeObjects::ClassObject.new(@root, name)

    model = load_model(file)
    add_class_documentation(svc, klass, model)
    add_methods(svc, klass, model)
    add_waiters(svc, klass, model)

    svc.docstring.add_tag(YARD::Tags::Tag.new(:service, identifier))
    svc.docstring.add_tag(YARD::Tags::Tag.new(:version, version))
    svc.superclass = 'AWS.Service'
  end

  def add_class_documentation(service, klass, model)
    docstring = ModelDocumentor.new(klass, model).lines.join("\n")
    parser = YARD::Docstring.parser
    parser.parse(docstring, service)
    service.docstring = parser.to_docstring
  end

  def add_methods(service, klass, model)
    model['operations'].each_pair do |name, operation|
      meth = YARDJS::CodeObjects::PropertyObject.new(service, name)
      docs = MethodDocumentor.new(operation, model, klass).lines.join("\n")
      meth.property_type = :function
      meth.parameters = [['params', '{}'], ['callback', nil]]
      meth.signature = "#{name}(params = {}, [callback])"
      meth.dynamic = true
      meth.docstring = docs
    end
  end

  def add_waiters(service, klass, model)
    return unless waiters = model['waiters']

    wait_for = YARDJS::CodeObjects::PropertyObject.new(service, 'waitFor')
    wait_for.property_type = :function
    wait_for.parameters = [['state', nil], ['params', '{}'], ['callback', nil]]
    wait_for.signature = "waitFor(state, params = {}, [callback])"
    wait_for.dynamic = true
    wait_for.docstring = <<-eof
Waits for a given #{service.name} resource. The final callback or
{AWS.Request~complete 'complete' event} will be fired only when the resource
is either in its final state or the waiter has timed out and stopped polling
for the final state.

@api experimental
@param state [String] the resource state to wait for. Available states for this
  service are listed in "Waiter Resource States" below.
@param params [map] a list of parameters for the given state. See each waiter
  resource state for required parameters.
@callback callback function(err, data)
  Callback containing error and data information. See the respective resource
  state for the expected error or data information.

  If the waiter times out its requests, it will return a `ResourceNotReady`
  error.
@return [AWS.Request] a handle to the operation request for subsequent event
  callback registration.
eof

    waiters.keys.each do |name|
      next if name =~ /^_/
      config = load_waiter(waiters, name)
      operation_name = config['operation'][0,1].downcase + config['operation'][1..-1]
      obj = WaiterObject.new(service, name)
      obj.operation = YARDJS::CodeObjects::PropertyObject.new(service, operation_name)
      obj.operation.docstring.add_tag YARD::Tags::Tag.new(:waiter, "{#{obj.path}}")
      obj.docstring = <<-eof
Waits for the `#{name}` state by periodically calling the underlying
{#{operation_name}} operation every #{config['interval']} seconds
(at most #{config['maxAttempts']} times).

@api experimental
@callback (see #{obj.operation.path})
@param (see #{obj.operation.path})
@return (see #{obj.operation.path})
@see #{operation_name}
eof

      waiter_ex = ExampleShapeVisitor.new(true).example(
        service.name.to_s.downcase, 'waitFor', model['operations'][operation_name]['input'])
      waiter_ex = waiter_ex.sub(/\.waitFor\(/, ".waitFor('#{name}', ")
      waiter_ex = waiter_ex.sub(/\{\s+\}/, "{\n  // ... input parameters ...\n}")
      obj.docstring.add_tag YARD::Tags::Tag.new(:example, waiter_ex, nil,
        "Waiting for the #{name} state")
      unless wait_for.docstring.tag(:example)
        wait_for.docstring.add_tag YARD::Tags::Tag.new(:example, waiter_ex, nil,
          "Waiting for the #{name} state")
      end

      wait_for.docstring.add_tag YARD::Tags::Tag.new(:waiter, "{#{obj.path}}")
    end
  end

  def load_waiter(waiters, name)
    waiter = waiters[name]
    if waiter['extends']
      waiter = waiter.merge(load_waiter(waiters, waiter['extends']))
    elsif name != '__default__'
      waiter = waiter.merge(load_waiter(waiters, '__default__'))
    end
    waiter
  end

  def load_model(file)
    data = File.read(file, 4096)
    endpoint_prefix = data[/"endpointPrefix":\s*"(.+?)"/, 1]

    dir = File.expand_path(File.dirname(file))
    name = File.basename(file).downcase
    name = name.sub(/^([^-]+)/, endpoint_prefix)
    file = dir + '/source/' + name
    translate = "require(\"#{dir}/../lib/translator\")(require(\"fs\")." +
                "readFileSync(\"#{file}\"), {documentation:true})"
    json = `node -e 'console.log(JSON.stringify(#{translate}))'`
    JSON.parse(json)
  end
end