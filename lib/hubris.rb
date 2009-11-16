require 'tmpdir'
require 'rubygems'
require 'open4'
require 'digest/md5'
require 'rbconfig'
# require 'libHaskell'
# TODO delete old files

class HaskellError < RuntimeError
end

def ruby_header_dir
  # Possible config values for 1.8.6:
  # archdir and topdir
  # For 1.9: rubyhdrdir
  Config::CONFIG['rubyhdrdir'] || Config::CONFIG['topdir'] 
end

module Hubris
  VERSION = '0.0.2'
  SO_CACHE = File.expand_path("~/.hubris_cache")
  
  system('mkdir ' + SO_CACHE)
  $:.push(SO_CACHE)

  @packages = []
  def self.add_packages(packages)
    @packages.concat packages
  end
  
  
  def self.find_suitable_ghc()
    # if HUBRIS_GHC is specified, don't try anything else.
    ghcs = ENV['HUBRIS_GHC'] ||  Dir.glob(ENV['PATH'].split(':').map {|p| p + "/ghc*" }).select {|x| x =~ /\/ghc(-[0-9\.]*)?$/}
    ghcs = ghcs.each { |candidate|
      version = `#{candidate} --numeric-version`.chomp
      return [candidate, version] if version >= '6.11' 
    }
    raise(HaskellError, "Can't find an appropriate ghc: tried #{ghcs}")
  end

  GHC,GHC_VERSION = Hubris::find_suitable_ghc
  RubyHeader = ruby_header_dir or raise HaskellError, "Can't get rubyhdrdir"

  # TODO add foreign export calls immediately for each toplevel func
  # cheap hacky way: first word on each line, nub it to get rid of
  # function types.
  # tricky bit: generating interface for each
  def self.extract_function_names(haskell_str)
    functions = {}
    haskell_str.each_line do |line|
      # skkeeeeeeetchy. FIXME use haskell-src-exts or something more sensible here
      # ok, so now we have ExtractHeaders. Can't really integrate it using Hubris,
      # for obvious reasons, but we can build an extension
      if /^[^ \-{].*/ =~ line
        functions[line.split(/ /)[0]] = 1
      end
    end    
    functions.keys
  end

  def self.make_haskell_bindings(functions)
    prelude =<<-EOF
{-# LANGUAGE ScopedTypeVariables, FlexibleInstances, ForeignFunctionInterface, UndecidableInstances #-}
-- import Foreign.Ptr()
import Language.Ruby.Hubris
import Prelude hiding (catch)
import Control.Exception(SomeException, evaluate, catch)
import Foreign(unsafePerformIO)
main :: IO ()
main = return ()

EOF
    bindings = ""
    # cheap way: assert type sigs binding to RValue. Might be able to do better after,
    # but this'll do for the moment
    functions.each do |fname|
      bindings +=<<-EOF
#{fname} :: RValue -> RValue
#{fname}_external :: Value -> Value -> Value
#{fname}_external _mod x = unsafePerformIO $
  (evaluate (toRuby $ #{fname} $ fromRuby x))
     `catch` (\\y -> throwException (show (y::SomeException)))
foreign export ccall "#{fname}_external" #{fname}_external :: Value -> Value -> Value

      EOF
    end
    return prelude + bindings
  end

  def self.trans_name(func)
    func.gsub(/Z/, 'ZZ').gsub(/z/, 'zz').gsub(/\./,'zd').gsub(/_/,'zu').gsub(/'/, 'zq') 
  end

  def self.base_loader_code mod_name, lib_name
    %~/* so, here's the story. We have the functions, and we need to expose them to Ruby */
/* this is about as filthy as it looks, but gcc chokes otherwise, with a redefinition error. */
#define HAVE_STRUCT_TIMESPEC 1 
#include <stdio.h>
#include "ruby.h"
VALUE #{mod_name} = Qnil;
extern void hs_init(int * argc, char ** argv[]);

void Init_#{lib_name}() {
    int argc = 1;
    // this needs to be allocated on the heap or we get a segfault
    char ** argv = malloc(sizeof(char**) * 1);
    argv[0]="haskell_extension";
//    printf("initialising #{lib_name}\\n");

    hs_init(&argc, &argv);
   // printf("initialised #{lib_name}\\n");
    #{mod_name} = rb_define_class("#{mod_name}", rb_cObject);
   // printf("defined classes for #{lib_name}\\n");
    ~

      # class Module; def hubris; self.class_eval { def self.h;"hubrified!";end };end;end
  end

  def self.make_stub(mod_name, lib_name, functions)
    loader_code = base_loader_code(mod_name, lib_name)

    functions.each do |function_name|
      loader_code += "VALUE #{function_name}_external(VALUE);\n"
      # FIXME add the stg roots as well
      #  loaderCode += "extern void __stginit_#{function_name}zuexternal(void);\n"
    end

    functions.each do |function_name|
      # FIXME this is the worng place to be binding methods. Can we bind a bare C method in Ruby
      # instead?
#      loader_code += "rb_define_method(#{mod_name},\"#{function_name}\",#{function_name}_external, 1);\n"
      loader_code += "rb_define_singleton_method(#{mod_name},\"#{function_name}\",#{function_name}_external, 1);\n"
      # FIXME this is needed for GHC
      # loader_code += "hs_add_root(__stginit_#{trans_name(function_name + '_external')});\n"
    end
    return loader_code + "}\n"
  end

  def self.dylib_suffix
    case Config::CONFIG['target_os']
    when /darwin/
       "bundle"
    when /linux/
       "so"
    else
       "so" #take a punt
    end
  end

  def self.builder
    'ghc'
  end

  def self.base_lib_dir
    File.expand_path( File.dirname(__FILE__))
  end

  # load the new functions into target_module
  def self.hubris(target_module, opts = { })
    
    options = { :no_strict => false }.merge opts
    if options.keys.select{ |x| x==:source || x==:module || x==:inline }.count != 1
      raise "Bad call - needs exactly one of :source, :module or :inline defined in hubris call"
    end
    if opt[:inline]
      # put the code in a temporary file, set opt[:source]
    end
    if opt[:source]
      # find the code, compile into haskell module in namespace, set 
    end

    if opt[:module]
      # search the loaded module for compatible signatures
      # bind them all into target_module
    else
      raise "code error, should never happen"
    end
    # this is a bit crap. You wouldn't have to specify the args in an FP language :/ 
    # should probably switch out to a couple of single-method classes
    # argh
    # """
    # Ruby's lambda is unusual in that choice of parameter names does affect behavior:
    # x = 3
    # lambda{|x| "x still refers to the outer variable"}.call(4)
    # puts x  # x is now 4, not 3
    # """
    # this is a solved problem, guys. come ON. FIXME

    builders = { "jhc" => lambda { |x,y,z,a| jhcbuild(x,y,z,a) }, "ghc" => lambda { |x,y,z,a| ghcbuild(x,y,z,a) } }

    signature = Digest::MD5.hexdigest(haskell_str)
    functions = extract_function_names(haskell_str)

    return unless functions.size > 0

    
    lib_name = "lib#{functions[0]}_#{signature}"; # unique signature
    lib_file = SO_CACHE + "/" + lib_name + '.' + dylib_suffix
    file_path = File.join(Dir.tmpdir, functions[0] + "_source.hs")


    # if the haskell libraries have changed out from under us, that's just too bad.
    # If we've changed details of this script, however, we probably want to rebuild,
    # just to be safe.
    if !File.exists?(lib_file) or File.mtime(__FILE__) >= File.mtime(lib_file) # or ENV['HUBRIS_ALWAYS_REBUILD']
      mod_name = self.class  
      write_hs_file( file_path, haskell_str, functions, mod_name, lib_name )
      File.open("stubs.c", "w") {|io| io.write(make_stub(mod_name, lib_name, functions))}
      # and it all comes together
#      build_result = builders[builder].call(lib_file, file_path , ['stubs.c', base_lib_dir + '/rshim.c'], build_options)
      build_result = builders[builder].call(lib_file, file_path , ['stubs.c'],
                                             # base_lib_dir + '/rshim.c'], 
                                            build_options)
      puts "built"
    end

    begin
      puts "requiring #{lib_name}"
      require lib_name
      puts "reqd"
      # raise LoadError
    rescue LoadError
      raise LoadError, "loading #{lib_name} failed, source was\n" + `cat #{file_path}` + 
                       "\n" + $!.to_s + "\n" + `nm #{lib_file} |grep 'ext'` + "\n" + 
                       (build_result || "no build result?") + "\n"
    end
  end

  def write_hs_file file_path, haskell_str, functions, mod_name, lib_name
    File.open( file_path , "w") do |file|
      # so the hashing algorithm doesn't collide if we try building the same code
      # with jhc and ghc.
      #
      # argh, this isn't quite right. If we inline the same code but on a new ruby module
      # this won't create the new stubs. We want to be able to use new stubs but with the
      # old haskell lib. FIXME
      file.print("-- COMPILED WITH #{builder}\n")
      file.print(make_haskell_bindings(functions))
      file.print(haskell_str)
      file.flush
    end
  end

  # This is obviously weak, but there are many ways people may have various GHC installations,
  # and the previous assumptions were also bad.  Need to decide if a) code should be super clever and
  # detect this sort of thing, or b) user should just set config values someplace.  Or c) some hybrid.
  # James likes (b).
  def ghc_build_path
    ENV['HUBRIS_GHC_BUILD_PATH'] || '/usr/local'
  end

  def ghcbuild(lib_file, haskell_path, extra_c_src, options)
    # this could be even less awful.
    # ghc-paths fixes this
    command = "#{GHC} -Wall -package hubris --make -dynamic -fPIC -shared #{haskell_path} " +
    " -lHSrts-ghc#{GHC_VERSION} " +
    # "-L#{ghc_build_path}/lib/ghc-#{GHC_VERSION} " +
     "-no-hs-main " +
   #  "-optl-Wl,-rpath,#{ghc_build_path}/lib/ghc-#{GHC_VERSION} " +
     "-o #{lib_file} " +  extra_c_src.join(' ') # -I  + Hubris::RubyHeader # + ' -I./lib'
    command += ' -Werror ' unless options[:no_strict] # bondage and discipline
    puts "\n|#{command}|\n"
    success,msg=noisy(command)
    # puts msg
    raise HaskellError, "ghc build failed " + msg + `cat #{haskell_path}` unless success
    return msg
  end

  def jhcbuild(lib_file, haskell_path, extra_c_src)
    noisy("rm hs.out_code.c 2>/dev/null")
    # puts "building\n#{file.read}"
    success, msg = noisy("jhc  -dc #{haskell_path} -papplicative -ilib")
    raise HaskellError, "JHC build failed:\nsource\n" + `cat #{haskell_path}` + "\n#{msg}" unless success || File.exists?("hs.out_code.c")
     
    # output goes to hs_out.code.c
    # don't need to grep out main any more
    # we do need to grep out rshim.h, though. why? no one knows. better solution please
    system("echo '#include <rshim.h>' > temp.c;")
    system("grep -v '#include \<rshim.h\>' < hs.out_code.c | sed  's/ALIGN(/JHCS_ALIGN(/g'  >> temp.c; mv temp.c hs.out_code.c;")

    # FIXME generalise to linux, this is probably Mac only.
    lDFLAGS = [ '-dynamiclib',
                '-fPIC',
                '-shared'
                # '-lruby',
    ]
    mACFLAGS = [
                '-undefined suppress',
                '-flat_namespace'
    ]
    cPPFLAGS = [
                '-D_GNU_SOURCE',
                '-D_JHC_STANDALONE=0',
                '-DNDEBUG'
    ]
    cFLAGS = ['-std=gnu99',
              '-falign-functions=4',
              '-ffast-math',
              '-Wshadow', '-Wextra', '-Wall', '-Wno-unused-parameter',
              "-g -O3 -o #{lib_file}"]
    sRC = [
           './hs.out_code.c'
    ] + extra_c_src

    iNCLUDES = ["-I#{RubyHeader}", '-I./lib']
    system "rm #{lib_file} 2>/dev/null"

    success, msg = noisy("gcc " + [cPPFLAGS, cFLAGS, lDFLAGS, iNCLUDES, sRC].join(" "))
    puts msg
    unless success
      raise SyntaxError, "C build failed:\n#{msg}"
    end
  end
end

def noisy(str)
  pid, stdin, stdout, stderr = Open4.popen4 str
  puts "waiting for #{pid}"
  ignored, status = Process.waitpid2 pid
  puts "#{pid} done"
  if status == 0
    [true, str + "\n"]
  else
    msg = <<-"EOF"
output: #{stdout.read}
error:  #{stderr.read}
    EOF
    [false, str + "\n" + msg]
  end
end

# this may be sketchy :)
class Module
  self.class_eval do
    def hubris(options)
      Hubris.hubris(self, options)
    end
  end
end
