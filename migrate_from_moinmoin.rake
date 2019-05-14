require 'active_record'
require 'iconv'
require 'pp'

# This version modified by Ward Vandewege <ward@jhvc.com>, 2011-11-06

namespace :redmine do
  desc 'MoinMoin migration script'
  task :migrate_from_moinmoin => :environment do
    module MMMigrate
      def self.migrate
        puts "No wiki defined" unless @target_project.wiki
        wiki = @target_project.wiki || 
          Wiki.new(:project => @target_project, 
                   :start_page => @target_project.name)

        migrated_wiki_attachments = 0
                   
        mm = MoinMoinWiki.new(@moin_moin_path)
        mm.each_page do |page|
          new_title = page['title'].gsub('/', '-')
          puts "Title: " + new_title
          p = wiki.find_or_new_page(new_title)
	  if new_title.include? "-"
	    p.parent_title = new_title
	    idx = p.parent_title.size - 1
	    while p.parent_title[idx] != '-'
	      idx = idx - 1
	    end
	    p.parent_title = p.parent_title[0..idx-1]
	    puts "Title #{new_title} Parent #{p.parent_title}"
	    p.save
	  end
          page['revisions'].each_with_index do |revision, i|
            p.content = WikiContent.new(:page => p) if p.new_record?
            content = p.content_for_version(i)
            content.text = self.convert_wiki_text(revision,mm)
            content.author = User.find_by_mail("tma@gatehouse.dk")
            content.comments = "Revision %d from MoinMoin." % i
            content.updated_on = page['revision_timestamps'][i]
          
            # Attachments
            page['attachments'].each do |attachment|
              next unless attachment.exist?
              next if p.attachments.find_by_filename(attachment.filename.gsub(/^.*(\\|\/)/, '').gsub(/[^\w\.\-]/,'_')) #add only once per page
              attachment.open {
                a = Attachment.new :created_on => attachment.time
                a.file = attachment
                a.author = User.find_by_mail("tma@gatehouse.dk")
                a.description = ''
                a.container = p
                if a.save
                  migrated_wiki_attachments += 1 
                else
                  pp a
                end
              }
            end

            #puts "  Text: " + content.text
            #puts "  Comment: " + p.content.comments
            #puts "  Timestamp: " + p.content.updated_on.to_s
            p.new_record? ? p.save : Time.fake(content.updated_on) { content.save }
          end
          puts "  Revisions:      #{page['revisions'].count}"
        end

        puts "Wiki files:      #{migrated_wiki_attachments}"

      end

      class ::Time
        class << self
          alias :real_now :now
          def now
            real_now - @fake_diff.to_i
          end
          def fake(time)
            @fake_diff = real_now - time
            res = yield
            @fake_diff = 0
           res
          end
        end
      end


      class MoinMoinAttachment
	attr_accessor :filename
	attr_accessor :moinmoin_fullpath

        def time
	  File.mtime(self.moinmoin_fullpath)
	end

        def size
	  File.size(self.moinmoin_fullpath)
	end

        def original_filename
          filename
        end

        def content_type
          ''
        end

        def exist?
          File.file? moinmoin_fullpath
        end

        def open
          File.open("#{moinmoin_fullpath}", 'rb') {|f|
            @file = f
            yield self
          }
        end

        def read(*args)
          @file.read(*args)
        end

        def description
          read_attribute(:description).to_s.slice(0,255)
        end
      end

       
      class MoinMoinWiki
        def initialize(path)
          @path = path
        end

        def process_page(folder)
          fpath = @path + "/" + folder + "/"
          r = {}

          folder.gsub!(/\(([a-z0-9]{2})\)/) {|s| "#{$1.hex.chr}"}

          r['title'] = folder

          r['revisions'] = []
          r['revision_timestamps'] = []
          rev_names = Dir.entries(fpath + "revisions").reject { |e| e == "." || e == ".." }
          rev_names.sort.each do |revision| 
            r['revisions'] << IO.read(fpath + "revisions" + "/" + revision)
            r['revision_timestamps'] << File.mtime(fpath + "revisions" + "/" + revision)
          end

          r['attachments'] = []
	  if File.exists?(fpath + "attachments") then
            rev_names = Dir.entries(fpath + "attachments").reject { |e| e == "." || e == ".." }
            rev_names.sort.each do |attachment| 
              m = MoinMoinAttachment.new();
              m.moinmoin_fullpath = fpath + "attachments" + "/" + attachment
              m.filename = attachment
              r['attachments'] << m
            end
          end

          r
        end

        def each_page()
          Dir.entries(@path).reject {|e| e == ".." || e == "."}.select{|e| File.directory? @path + "/" + e}.each do |page_folder|
            # Is it a valid page?
            next unless Dir.entries(@path + "/" + page_folder).include?("revisions")
            yield process_page(page_folder)
          end
        end
      end
      
      def self.target_project_identifier(identifier)    
        project = Project.find_by_identifier(identifier)
      
        if !project
          abort "Project #{identifier} not found"
        else      
          puts "Found Project: " + project.to_yaml
        end        
      
        @target_project = project.new_record? ? nil : project
      end

      def self.target_moin_moin_path(path)    
        @moin_moin_path = path
      end
      
      def self.find_or_create_user(email, project_member = false)
        u = User.find_by_mail(email)
        if !u
          u = User.find_by_mail(@@mw_default_user)
        end
        if(!u)
          # Create a new user if not found
          mail = email[0,limit_for(User, 'mail')]
          mail = "#{mail}@fortna.com" unless mail.include?("@")
          name = email[0,email.index("@")];
          u = User.new :firstname => name[0,limit_for(User, 'firstname')].gsub(/[^\w\s\'\-]/i, '-'),
                       :lastname => '-',
                       :mail => mail.gsub(/[^-@a-z0-9\.]/i, '-')
          u.login = email[0,limit_for(User, 'login')].gsub(/[^a-z0-9_\-@\.]/i, '-')
          u.password = 'bugzilla'
          u.admin = false
          # finally, a default user is used if the new user is not valid
          puts "Created User: "+ u.to_yaml
          u = User.find(:first) unless u.save
        else
           puts "Found User: " + u.to_yaml
        end
        # Make sure he is a member of the project
        if project_member && !u.member_of?(@target_project)
          role = ROLE_MAPPING['developer']
          Member.create(:user => u, :project => @target_project, :role => role)
          u.reload
        end
        u
      end
      
      # Basic wiki syntax conversion
      def self.convert_wiki_text(text,mm)
        # Titles
        text = text.gsub(/^(\=+)\s*([^=]+)\s*\=+\s*$/) {|s| "\nh#{$1.length}. #{$2}\n"}
        # Internal links
        text = text.gsub(/\[\[(.*)\s+\|(.*)\]\]/) {|s| "[[#{$1}|#{$2}]]"}
        text = text.gsub(/\["([^"]*)"\]/) {|s| "[[#{$1}]]"}
	# Catch wikiwords with 2 or 3 parts
        text = text.gsub(/(\s+)(([A-Z][a-z0-9]+){2,})(\s+|,)/) {|s| "#{$1}[[#{$2}]]#{$4}"}
	# No more need for explicit linebreaks
        text = text.gsub(/\[\[BR\]\]/) {|s| ""}
        # External Links
        text = text.gsub(/\[(http[^\s]+)\s+([^\]]+)\]/) {|s| "\"#{$2}\":#{$1}"}
        text = text.gsub(/\[(http[^\s]+)\]/) {|s| "#{$1}"}
        # Highlighting
        text = text.gsub(/'''''([^\s])/, '_*\1')
        text = text.gsub(/([^\s])'''''/, '\1*_')
        text = text.gsub(/'''([^\s])/, '*\1')
        text = text.gsub(/([^\s])'''/, '\1*')
        text = text.gsub(/''([^\s])/, '_*\1')
        text = text.gsub(/([^\s])''/, '\1*_')
        # code
        #text = text.gsub(/((^ [^\n]*\n)+)/m) { |s| "<pre>\n#{$1}</pre>\n" }
        #text = text.gsub(/(^\n^ .*?$)/m) { |s| "<pre><code>#{$1}" }
        #text = text.gsub(/(^ .*?\n)\n/m) { |s| "#{$1}</pre></code>\n" }
        text = text.gsub(/\{\{\{\s*$/) { |s| "<pre><code>" }
        text = text.gsub(/\}\}\}\s*$/) { |s| "</code></pre>\n" }
        text = text.gsub(/\{\{\{/) { |s| "<pre><code>" }
        text = text.gsub(/\}\}\}/) { |s| "</code>" }
        # Some silly leading whitespace.
        text = text.gsub(/<pre><code>\n/m) { |s| "<pre><code>" }        
        text = text.gsub('#!cplusplus', '')
        
        # Tables
        # Half-assed attempt
        # First strip off the table formatting
        text = text.gsub(/^\![^\|]*/, '')
        text = text.gsub(/^\{\|[^\|]*$/, '{|')
        # Now congeal the rows
        while( text.gsub!(/(\|-.*)\n(\|\w.*)$/m, '\1\2'))
        end
        # Now congeal the headers
        while( text.gsub!(/(\{\|.*)\n(\|\w.*)$/m, '\1\2'))
        end
        # format the headers properly
        while( text.gsub!(/(\{\|.*)\|([^_].*)$/, '\1|_. \2'))
        end
        # get rid of leading '{|'
        text = text.gsub(/^\{\|(.*)$/) { |s| "table(stdtbl)\n#{$1}|" }
        # get rid of leading '|-'
        text = text.gsub(/^\|-(.*)$/, '\1|')
        # get rid of trailing '|}'
        text = text.gsub(/^\|\}.*$/, '')
        # Internal Links
        text = text.gsub(/\[\[Image:([^\s]+)\]\]/) { |s| "!#{$1}!" }
        # Wiki page separator ':'
        while( text.gsub!(/(\[\[\s*\w+):(\w+)/, '\1_\2') )
        end

	# inline image attachments
        text = text.gsub(/\s*attachment:([^\s\.]+)\.(jpg|gif|png)/i) {|s| "\n\n!#{$1}.#{$2}!"}
        text = text.gsub(/\s*attachment:([^\s]+)/i) {|s| "\n\nattachment:#{$1}"}

	# throw away pragma statements
	#puts text
        text = text.gsub(/^#pragma (.*)$/isu) {|s| ""}

        text
      end
    end

    def prompt(text, options = {}, &block)
      default = options[:default] || ''
      while true
        print "#{text} [#{default}]: "
        value = STDIN.gets.chomp!
        value = default if value.blank?
        break if yield value
      end
    end    
    
    MMMigrate.target_project_identifier 'ais'
    MMMigrate.target_moin_moin_path '/home/bitnami/moin/pages'
    MMMigrate.migrate    
  end
end
