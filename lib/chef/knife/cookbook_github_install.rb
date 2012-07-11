#
# Author:: Adam Jacob (<adam@opscode.com>)
# Author:: Jesse Newland (<jesse@websterclay.com>)
# Copyright:: Copyright (c) 2010 Opscode, Inc.
# Copyright:: Copyright (c) 2011 Webster Clay, LLC.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/knife'
require 'tempfile'

class Chef
  class Knife

    class CookbookGithubInstall < Knife

      deps do
        require 'chef/mixin/shell_out'
        require 'chef/knife/core/cookbook_scm_repo'
        require File.join(File.dirname(__FILE__), 'core', 'coobook_scm_repo_extensions')
      end

      banner "knife cookbook github install USER/REPO [USER/REPO/BRANCH] (options)"
      category "cookbook"

      option :ssh,
       :short => "-S",
       :long => "--ssh",
       :boolean => true,
       :description => "Use the git@ style url. Defaults to true if $USER matches user/repo"

      option :cookbook_path,
        :short => "-o PATH:PATH",
        :long => "--cookbook-path PATH:PATH",
        :description => "A colon-separated path to look for cookbooks in",
        :proc => lambda { |o| o.split(":") }

      option :default_branch,
        :short => "-B BRANCH",
        :long => "--branch BRANCH",
        :description => "Default branch to work with",
        :default => "master"

      attr_reader :github_user
      attr_reader :github_repo
      attr_reader :github_branch
      attr_reader :cookbook_name

      def run
        extend Chef::Mixin::ShellOut

        if config[:cookbook_path]
          Chef::Config[:cookbook_path] = config[:cookbook_path]
        else
          config[:cookbook_path] = Chef::Config[:cookbook_path]
        end

        parse_name_args!

        @install_path = File.expand_path(config[:cookbook_path].first)
        ui.info "Installing #@cookbook_name from #{github_uri} to #{@install_path}"

        @repo = CookbookSCMRepoExtensions.new(@install_path, ui, config)

        ensure_cookbooks_path_exists
        
        @repo.sanity_check
        @repo.reset_to_default_state
        @repo.prepare_to_import(@cookbook_name)

        clone_cookbook
        clear_existing_files(File.join(@install_path, @cookbook_name))
        move_cookbook

        if @repo.finalize_updates_from_github(@cookbook_name, "#{@github_user}/#{@github_repo}", sha)
          @repo.reset_to_default_state
          ensure_cookbooks_path_exists
          @repo.merge_updates_from(@cookbook_name, sha)
        else
          @repo.reset_to_default_state
        end
      end

      def parse_name_args!
        if name_args.empty?
          ui.error("please specify a cookbook to download and install")
          exit 1
        elsif name_args.size > 1
          ui.error("Usage: knife cookbook github install USER/REPO [USER/REPO/BRANCH] (options)")
          exit 1
        else
          @github_user, @github_repo, @github_branch = name_args.first.split('/')
          unless @github_user && @github_repo
            ui.error("Expected a github user and a repo to download from: jnewland/chef_ipmi")
            exit 1
          end
          @cookbook_name = @github_repo.gsub(/[_-]?chef(?!-client|-server|_handler)[-_]?/, '').
                                        gsub(/[_-]?cookbook[-_]?/, '')
        end
      end

      def temp_clone_path
        "_tmp_chef_#{@cookbook_name}"
      end

      def tmpdir
        Dir.tmpdir
      end

      def clone_cookbook
        shell_out!("rm -rf #{temp_clone_path}", :cwd => tmpdir) if File.exists?(File.join(tmpdir, temp_clone_path))
        shell_out!("git clone #{github_uri} #{temp_clone_path}", :cwd => tmpdir)
        shell_out!("git checkout #{github_branch}", :cwd => File.join(tmpdir, temp_clone_path))
        shell_out!("rm -rf .git", :cwd => File.join(tmpdir, temp_clone_path))
      end

      def move_cookbook
        shell_out!("mv #{temp_clone_path} #{File.join(@install_path, @cookbook_name)}", :cwd => tmpdir)
      end

      def clear_existing_files(cookbook_path)
        ui.info("Removing pre-existing version.")
        shell_out!("rm -r #{cookbook_path}", :cwd => @install_path) if File.directory?(cookbook_path)
      end

      def ensure_cookbooks_path_exists
        shell_out!("mkdir -p #{@install_path}", :cwd => tmpdir) unless File.exists?(@install_path)
      end

      def github_uri
        if config[:ssh] || @github_user == ENV['USER']
          "git@github.com:#{@github_user}/#{@github_repo}.git"
        else
          "git://github.com/#{@github_user}/#{@github_repo}.git"
        end
      end

      def sha
        @sha ||= begin
                   data = sha_for_branch_or_tag
                   data['object']['sha']
                 end
      end

      def github_branch
        @github_branch ||= 'master'
      end

      # tries for the branch and then the tag
      def sha_for_branch_or_tag
        begin
          # try for the branch first
          data = noauth_rest.get_rest("https://api.github.com/repos/#{@github_user}/#{@github_repo}/git/refs/heads/#{github_branch}")
        rescue Net::HTTPServerException, Net::HTTPFatalError => e
          # try for the tag if the branch was not found
          data = noauth_rest.get_rest("https://api.github.com/repos/#{@github_user}/#{@github_repo}/git/refs/tags/#{github_branch}")
        end
        data
      end

    end
  end
end

