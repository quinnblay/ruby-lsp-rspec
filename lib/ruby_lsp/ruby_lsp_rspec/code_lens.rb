# typed: strict
# frozen_string_literal: true

module RubyLsp
  module RSpec
    class CodeLens
      extend T::Sig

      include ::RubyLsp::Requests::Support::Common

      sig do
        params(
          response_builder: ResponseBuilders::CollectionResponseBuilder[Interface::CodeLens],
          uri: URI::Generic,
          dispatcher: Prism::Dispatcher,
          rspec_command: T.nilable(String),
          debug: T::Boolean,
        ).void
      end
      def initialize(response_builder, uri, dispatcher, rspec_command: nil, debug: false)
        @response_builder = response_builder

        # Get the workspace root and current file path
        workspace_root = Pathname.new(Dir.pwd)
        file_path = Pathname.new(T.must(uri.to_standardized_path))

        # Calculate the relative path from workspace root
        @path = T.let(file_path.relative_path_from(workspace_root).to_s, String)

        @group_id = T.let(1, Integer)
        @group_id_stack = T.let([], T::Array[Integer])
        @anonymous_example_count = T.let(0, Integer)
        dispatcher.register(self, :on_call_node_enter, :on_call_node_leave)

        @debug = debug

        # Let's try the new rspec_command first
        # "dc exec api-backend bundle exec spring rspec",
        @base_command = T.let(
          # The user-configured command takes precedence over inferred command default
          rspec_command || begin
            cmd = if File.exist?(File.join(Dir.pwd, "bin", "rspec"))
              "bin/rspec"
            else
              "rspec"
            end

            if File.exist?("Gemfile.lock")
              "bundle exec #{cmd}"
            else
              cmd
            end
          end,
          String,
        )
      end

      sig { params(node: Prism::CallNode).void }
      def on_call_node_enter(node)
        case node.message
        when "example", "it", "specify"
          name = generate_name(node)
          add_test_code_lens(node, name: name, kind: :example)
        when "context", "describe"
          return unless valid_group?(node)

          name = generate_name(node)
          add_test_code_lens(node, name: name, kind: :group)

          @group_id_stack.push(@group_id)
          @group_id += 1
        end
      end

      sig { params(node: Prism::CallNode).void }
      def on_call_node_leave(node)
        case node.message
        when "context", "describe"
          return unless valid_group?(node)

          @group_id_stack.pop
        end
      end

      private

      sig { params(message: String).void }
      def log_message(message)
        puts "[#{self.class}]: #{message}"
      end

      sig { params(node: Prism::CallNode).returns(T::Boolean) }
      def valid_group?(node)
        !(node.block.nil? || (node.receiver && node.receiver&.slice != "RSpec"))
      end

      sig { params(node: Prism::CallNode).returns(String) }
      def generate_name(node)
        arguments = node.arguments&.arguments

        if arguments
          argument = arguments.first

          case argument
          when Prism::StringNode
            argument.content
          when Prism::CallNode
            "<#{argument.name}>"
          when nil
            ""
          else
            argument.slice
          end
        else
          @anonymous_example_count += 1
          "<unnamed-#{@anonymous_example_count}>"
        end
      end

      sig { params(node: Prism::Node, name: String, kind: Symbol).void }
      def add_test_code_lens(node, name:, kind:)
        line_number = node.location.start_line

        # Command for terminal execution (with Docker)
        terminal_command = "#{@base_command} #{@path}:#{line_number}"

        # Command for Test Runner execution (without Docker prefix)
        # The Test Runner needs just the basic command as it handles the execution context
        runner_command = "bundle exec rspec #{@path}:#{line_number}"

        log_message("Full command: `#{command}`") if @debug

        grouping_data = { group_id: @group_id_stack.last, kind: kind }
        grouping_data[:id] = @group_id if kind == :group

        arguments = [
          @path,
          name,
          runner_command, # Using runner_command for the Run option
          {
            start_line: node.location.start_line - 1,
            start_column: node.location.start_column,
            end_line: node.location.end_line - 1,
            end_column: node.location.end_column,
          },
        ]

        terminal_arguments = arguments.clone
        terminal_arguments[2] = terminal_command # Using terminal_command for Run In Terminal option

        @response_builder << create_code_lens(
          node,
          title: "Run",
          command_name: "rubyLsp.runTest",
          arguments: arguments,
          data: { type: "test", **grouping_data },
        )

        @response_builder << create_code_lens(
          node,
          title: "Run In Terminal",
          command_name: "rubyLsp.runTestInTerminal",
          arguments: terminal_arguments,
          data: { type: "test_in_terminal", **grouping_data },
        )

        @response_builder << create_code_lens(
          node,
          title: "Debug",
          command_name: "rubyLsp.debugTest",
          arguments: arguments,
          data: { type: "debug", **grouping_data },
        )
      end
    end
  end
end
