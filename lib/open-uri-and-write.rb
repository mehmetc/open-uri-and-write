require 'stringio'
require 'uri'
require 'open-uri'
require 'net/dav'
require 'highline/import'


# A wrapper for Net::Dav that acts as a replacement for the File class
class OpenUriAndWrite < StringIO

  alias_method :original_puts, :puts
  attr_accessor :dav, :filemode

  def initialize(url, rest)
    super("")
    @url = url
    @uri = URI.parse(url)
    if(rest.size > 0)
      @filemode = rest.first.to_s
      if(@filemode[/^[rwa]/])
        @dav = Net::DAV.new(@url)
        options = rest[1]
        if(options && options[:username] && options[:password])
          @dav.credentials(options[:username], options[:password])
        else
          set_credentials
        end
      end

      if(@filemode[/^a/])
        write(@dav.get(@url)) # Write to StringIO
      end

    end
  end

  def set_credentials
    if(ENV['DAVUSER'])
      username = ENV['DAVUSER']
    else
      username = ask("Username for #{@uri.host}: ")
      # TODO: Store username and hostname in .open-uri-and-write-hosts
    end

    if(ENV['DAVPASS'])
      password = ENV['DAVPASS']
    else
      osx = (RUBY_PLATFORM =~ /darwin/)
      osx_keychain = false
      if(osx)
        begin
          require 'osx_keychain'
          osx_keychain = true
        rescue LoadError
        end
      end
      if(osx_keychain)then
          keychain = OSXKeychain.new
          password = keychain[@uri.host, username ]
          if(!password)
            password = ask("Password for '#{username}@#{@uri.host}: ") {|q| q.echo = "*"}
            keychain[@uri.host, username] = password
            puts "Password for '#{username}@#{@uri.host}' stored on OS X KeyChain."
          end

      else
        password = ask("Password for '#{username}@#{@uri.host}: ") {|q| q.echo = "*"}
      end
    end
    @dav.credentials(username, password)
  end

  def puts(string)
    if(@filemode[/^r/])
      raise IOError.new(true), "not opened for writing"
    end

    super(string)
    @dav.put_string(@url, string)
  end

  def read
    @dav.get(@url)
  end

  def proppatch(xml_snippet)
    @dav.proppatch(@uri, xml_snippet)
  end

  def propfind
    @dav.propfind(@url)
  end

  def close
    @dav.put_string(@url, string)
  end

end

# Kernel extensions
# Careful monkeypatching
module Kernel
  private
  alias open_uri_and_write_original open # :nodoc:

  def open(name, *rest, &block) # :doc:
    if name.respond_to?(:open)
      name.open(*rest, &block)
    elsif name.respond_to?(:to_s) and
          name[/^(https?):\/\//] and
          rest.size > 0 and
          rest.first.to_s[/^[rwa]/]
      webdav_agent = OpenUriAndWrite.new(name, rest)
      if(block)
        yield webdav_agent
      else
        return webdav_agent
      end
    else
      open_uri_and_write_original(name, *rest, &block)
    end
  end

  module_function :open
end

# Store credentials for later use in sesssion.
class OpenUriAndWriteCredentialsStore

  def self.get_connection_for_url(url)
    hostname = URI.parse(url).host.to_s
    if(!$_webdav_credentials_pool)
      $_webdav_credentials_pool = { }
    end
    if($_webdav_credentials_pool[hostname])
      return $_webdav_credentials_pool[hostname]
    else(!$_webdav_credentials_pool[hostname])
      agent = OpenUriAndWrite.new(url, ['w'])
      $_webdav_credentials_pool[hostname] = agent.dav
      return agent.dav
    end
  end

end


# More monkeypatching
class Dir

  class << self
    alias original_mkdir mkdir
    alias original_rmddir rmdir
  end

  def self.mkdir(name)
    if name.respond_to?(:to_s) and name[/^(https?):\/\//]
      dav = OpenUriAndWriteCredentialsStore.get_connection_for_url(name)
      dav.mkdir(name)
    else
      self.original_mkdir(name)
    end
  end

  def self.rmdir(name)
    if name.respond_to?(:to_s) and name[/^(https?):\/\//]
      dav = OpenUriAndWriteCredentialsStore.get_connection_for_url(name)
      dav.delete(name)
    else
      self.original_rmdir(name)
    end
  end

  def self.propfind(name)
    if name.respond_to?(:to_s) and name[/^(https?):\/\//]
      dav = OpenUriAndWriteCredentialsStore.get_connection_for_url(name)
      dav.propfind(name)
    else
      # TODO Throw illegal action exception
    end
  end

  def self.proppatch(name,xml_snippet)
    if name.respond_to?(:to_s) and name[/^(https?):\/\//]
      dav = OpenUriAndWriteCredentialsStore.get_connection_for_url(name)
      dav.propfind(name, xml_snippet)
    else
      # TODO Throw illegal action exception
    end
  end

end

# Even more monkeypatching
class File

  class << self
    alias original_delete delete
    alias original_open open
    alias original_exists? exists?
  end

  def self.exists?(name)
    if(name[/https?:\/\//])
      dav = OpenUriAndWriteCredentialsStore.get_connection_for_url(name)
      dav.exists?(name)
    else
      self.original_exists?(name)
    end
  end

  def self.delete(names)
    filenames = []
    if(names.class == String)
      filenames << names
    elsif(names.class = Array)
      filenames = names
    end
    filenames.each do |filename|
      if(filename[/^(https?):\/\//])
        dav = OpenUriAndWriteCredentialsStore.get_connection_for_url(filename)
        dav.delete(filename)
      else
        self.original_delete(filename)
      end
    end
  end

  def self.open(name, *rest, &block)
    if name.respond_to?(:open)
      name.open(*rest, &block)
    elsif name.respond_to?(:to_s) and name[/^(https?):\/\//] and rest.size > 0 and rest.first.to_s[/^w/]
      webdav_agent = OpenUriAndWrite.new(name, rest)
      if(block)
        yield webdav_agent
      else
        return webdav_agent
      end
    else
      self.original_open(name, *rest, &block)
    end
  end

end
