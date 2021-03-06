require "test_helper"
require "stringio"

require "rbs/cli"

class RBS::CliTest < Minitest::Test
  CLI = RBS::CLI

  def stdout
    @stdout ||= StringIO.new
  end

  def stderr
    @stderr ||= StringIO.new
  end

  def with_cli
    yield CLI.new(stdout: stdout, stderr: stderr)
  ensure
    @stdout = nil
    @stderr = nil
  end

  def test_ast
    with_cli do |cli|
      cli.run(%w(-r set ast))

      # Outputs a JSON
      JSON.parse stdout.string
    end
  end

  def test_no_stdlib_option
    with_cli do |cli|
      cli.run(%w(--no-stdlib ast))

      assert_equal '[]', stdout.string
    end
  end

  def test_list
    with_cli do |cli|
      cli.run(%w(-r pathname list))
      assert_match %r{^::Pathname \(class\)$}, stdout.string
      assert_match %r{^::Kernel \(module\)$}, stdout.string
      assert_match %r{^::_Each \(interface\)$}, stdout.string
    end

    with_cli do |cli|
      cli.run(%w(-r pathname list --class))
      assert_match %r{^::Pathname \(class\)$}, stdout.string
      refute_match %r{^::Kernel \(module\)$}, stdout.string
      refute_match %r{^::_Each \(interface\)$}, stdout.string
    end

    with_cli do |cli|
      cli.run(%w(-r pathname list --module))
      refute_match %r{^::Pathname \(class\)$}, stdout.string
      assert_match %r{^::Kernel \(module\)$}, stdout.string
      refute_match %r{^::_Each \(interface\)$}, stdout.string
    end

    with_cli do |cli|
      cli.run(%w(-r pathname list --interface))
      refute_match %r{^::Pathname \(class\)$}, stdout.string
      refute_match %r{^::Kernel \(module\)$}, stdout.string
      assert_match %r{^::_Each \(interface\)$}, stdout.string
    end
  end

  def test_ancestors
    with_cli do |cli|
      cli.run(%w(-r set ancestors ::Set))
      assert_equal <<-EOF, stdout.string
::Set[A]
::Enumerable[A, self]
::Object
::Kernel
::BasicObject
      EOF
    end

    with_cli do |cli|
      cli.run(%w(-r set ancestors --instance ::Set))
      assert_equal <<-EOF, stdout.string
::Set[A]
::Enumerable[A, self]
::Object
::Kernel
::BasicObject
      EOF
    end

    with_cli do |cli|
      cli.run(%w(-r set ancestors --singleton ::Set))
      assert_equal <<-EOF, stdout.string
singleton(::Set)
singleton(::Object)
singleton(::BasicObject)
::Class
::Module
::Object
::Kernel
::BasicObject
      EOF
    end
  end

  def test_methods
    with_cli do |cli|
      cli.run(%w(-r set methods ::Set))
      cli.run(%w(-r set methods --instance ::Set))
      cli.run(%w(-r set methods --singleton ::Set))
    end
  end

  def test_method
    with_cli do |cli|
      cli.run(%w(-r set method ::Object yield_self))
      assert_equal <<-EOF, stdout.string
::Object#yield_self
  defined_in: ::Object
  implementation: ::Object
  accessibility: public
  types:
      [X] () { (self) -> X } -> X
    | () -> ::Enumerator[self, untyped]
      EOF
    end
  end

  def test_validate
    with_cli do |cli|
      cli.run(%w(-r set validate))
    end

    with_cli do |cli|
      Dir.mktmpdir do |dir|
        (Pathname(dir) + 'a.rbs').write(<<~RBS)
        class Hello::World
        end
        RBS

        error = assert_raises RBS::NoTypeFoundError do
          cli.run(["-I", dir, "validate"])
        end

        assert_equal "::Hello", error.type_name.to_s
      end
    end

    with_cli do |cli|
      Dir.mktmpdir do |dir|
        (Pathname(dir) + 'a.rbs').write(<<~RBS)
        Hello::World: Integer
        RBS

        error = assert_raises RBS::NoTypeFoundError do
          cli.run(["-I", dir, "validate"])
        end

        assert_equal "::Hello", error.type_name.to_s
      end
    end

    with_cli do |cli|
      Dir.mktmpdir do |dir|
        (Pathname(dir) + 'a.rbs').write(<<~RBS)
        type Hello::t = Integer
        RBS

        error = assert_raises RBS::NoTypeFoundError do
          cli.run(["-I", dir, "validate"])
        end

        assert_equal "::Hello", error.type_name.to_s
      end
    end
  end

  def test_constant
    with_cli do |cli|
      cli.run(%w(-r set constant Pathname))
      cli.run(%w(-r set constant --context File IO))
    end
  end

  def test_version
    with_cli do |cli|
      cli.run(%w(-r set version))
    end
  end

  def test_paths
    with_cli do |cli|
      cli.run(%w(-r set -r racc -I sig/test paths))
      assert_match %r{/stdlib/builtin \(dir, stdlib\)$}, stdout.string
      assert_match %r{/stdlib/set \(dir, library, name=set\)$}, stdout.string
      assert_match %r{/racc-\d\.\d\.\d+/sig \(absent, gem, name=racc, version=\)$}, stdout.string
      assert_match %r{^sig/test \(absent\)$}, stdout.string
    end
  end

  def test_vendor
    Dir.mktmpdir do |d|
      Dir.chdir(d) do
        with_cli do |cli|
          cli.run(%w(vendor --vendor-dir=dir1 --stdlib rbs-amber racc))

          assert_operator Pathname(d) + "dir1/stdlib", :directory?
          assert_operator Pathname(d) + "dir1/gems", :directory?
          assert_operator Pathname(d) + "dir1/gems/rbs-amber", :directory?
          refute_operator Pathname(d) + "dir1/gems/racc", :directory?
        end
      end
    end
  end

  def test_parse
    Dir.mktmpdir do |dir|
      dir = Pathname(dir)
      dir.join('syntax_error.rbs').write(<<~RBS)
        class C
          def foo: () ->
        end
      RBS
      dir.join('semantics_error.rbs').write(<<~RBS)
        interface _I
          def self.foo: () -> void
        end
      RBS
      dir.join('no_error.rbs').write(<<~RBS)
        class C
          def foo: () -> void
        end
      RBS

      with_cli do |cli|
        assert_raises(SystemExit) { cli.run(%W(parse #{dir})) }

        assert_equal [
          "#{dir}/semantics_error.rbs:2:2: Interface cannot have singleton method",
          "#{dir}/syntax_error.rbs:3:0: parse error on value: (kEND)",
        ], stdout.string.split("\n").sort
      end
    end
  end

  def test_prototype_no_parser
    Dir.mktmpdir do |dir|
      with_cli do |cli|
        def cli.has_parser?
          false
        end

        assert_raises SystemExit do
          cli.run(%w(prototype rb))
        end

        assert_raises SystemExit do
          cli.run(%w(prototype rbi))
        end

        assert_equal "Not supported on this interpreter (ruby).\n", stdout.string.lines[0]
        assert_equal "Not supported on this interpreter (ruby).\n", stdout.string.lines[1]
      end
    end
  end
end
