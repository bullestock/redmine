require 'active_record'
require 'iconv'
require 'pp'

# This version modified by Ward Vandewege <ward@jhvc.com>, 2011-11-06

namespace :redmine do
  desc 'MoinMoin migration script'
  task :migrate_from_moinmoin => :environment do
    module MMMigrate
      #@single_page = 'AISHub'

      def self.migrate
        puts "No wiki defined" unless @target_project.wiki
        wiki = @target_project.wiki || 
          Wiki.new(:project => @target_project, 
                   :start_page => @target_project.name)

        migrated_wiki_attachments = 0
	errors = 0
                   
        mm = MoinMoinWiki.new(@moin_moin_path)
	pageno = 1
        mm.each_page do |page|
	  if !page
	    next
	  end
          new_title = page['title'].gsub('/', '\\').gsub('-', '_').gsub('P\\GH\\AIS\\', '').gsub('P\\GH\\AIS', '')
          if @single_page && @single_page != new_title
            next
          end
          #puts "Title: " + new_title
          p = wiki.find_or_new_page(new_title)
	  #puts "New: #{p.new_record?}"
	  is_new = p.new_record?
	  if new_title.include? "-"
	    p.parent_title = new_title
	    idx = p.parent_title.size - 1
	    while p.parent_title[idx] != '-'
	      idx = idx - 1
	    end
	    p.parent_title = p.parent_title[0..idx-1]
	    #p.save
	    #puts "Title #{new_title} Parent #{p.parent_title}"
	  end
	  puts "Page #{pageno}: #{new_title}"
	  pageno = pageno + 1
	  begin
            content = nil
            page['revisions'].each_with_index do |revision, i|
	      rev = page['revision_ids'][i]
	      #puts "Rev #{i}: #{rev}"
	      p.content = WikiContent.new(:page => p) if is_new
	      content = p.content_for_version(i)
	      if !content
	        puts "Content: #{p.content}"
		abort "ABORT: No content for version #{i}"
	      end
	      content.text = self.convert_wiki_text(revision, mm, p)
              #puts "Text: #{content.text}"
	      content.author = User.find_by_mail("tma@gatehouse.dk")
	      if rev == 0
	        abort "Revision is zero for #{new_title}"
	      end
	      content.comments = "Revision %s from MoinMoin." % rev
	      content.updated_on = page['revision_timestamps'][i]
            end
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

	    puts "  Revisions:      #{page['revisions'].count}"
	  rescue StandardError => e
	    puts "Exception: #{e}"
	    errors = errors + 1
	    next
	  end
        end

        puts "Wiki pages:      #{pageno-1}"
        puts "Wiki files:      #{migrated_wiki_attachments}"
        puts "Errors:          #{errors}"

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
          r['revision_ids'] = []
          rev_names = Dir.entries(fpath + "revisions").reject { |e| e == "." || e == ".." }
	  last_rev = 0
          rev_names.sort.each do |revision|
	    #puts "REV #{revision}"
            r['revisions'] << IO.read(fpath + "revisions" + "/" + revision)
            r['revision_timestamps'] << File.mtime(fpath + "revisions" + "/" + revision)
            r['revision_ids'] << revision
	    rev = revision.to_i
	    if rev > last_rev
  	      last_rev = rev
	    end
          end
          current = IO.read(fpath + "current").to_i
          if current > last_rev
	    # Deleted page
	    return nil
          end
	  #puts "OK: #{folder} current #{current} last #{last_rev}"

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
        #else      
        #  puts "Found Project: " + project.to_yaml
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
      def self.convert_wiki_text(text, mm, p)
        #puts "--- CONVERT"
        new_text = ''
        text.each_line { |line|
          # Processing instructions
          line = line.gsub(/^#.*$/, '')
          # Macros
          line = line.gsub(/^<<.*$/, '')
          # Titles
          line = line.gsub(/^(\=+)\s*([^=]+)\s*\=+\s*$/) {|s| "\nh#{$1.length}. #{$2}\n"}

	  # attachments
          line = line.gsub(/\[\[attachment:([a-zA-Z0-9_\.]+)\]\]/i) {|s| "attachment:#{$1}"}
          
          # External links
          old_line = line
          line = line.gsub(/\[\[http:\/\/([A-Za-z0-9\-:\.\/_]+)\|([a-zA-Z0-9 \/]*)\]\]/) {|s| "\"#{$2}\":http://#{$1}"}
          if line == old_line
            line = line.gsub(/\[\[https:\/\/([A-Za-z0-9\-:\.\/_]+)\|([a-zA-Z0-9 \/]*)\]\]/) {|s| "\"#{$2}\":https://#{$1}"}
          end
          if line == old_line
            # Internal links
            parent = p.parent_title
            current = p.title + '\\'
            if current == 'Wiki\\'
              current = ''
            end

            old_line = line
            # Internal absolute top-level link (3 levels) to subpage, no alternate title
            line = line.gsub(/\[\[P\/GH\/AIS\/([A-Za-z0-9_]+)\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_ \-]+)\]\]/) {|s| "[[#{$1}\\#{$2}\\#{$3}]]"}
            if line == old_line
              # Internal absolute top-level link (2 levels) to subpage, no alternate title
              line = line.gsub(/\[\[P\/GH\/AIS\/([A-Za-z0-9_]+)\/([A-Za-z0-9_ \-]+)\]\]/) {|s| "[[#{$1}\\#{$2}]]"}
              if line == old_line
                # Internal absolute top-level link (1 level) to subpage, no alternate title
                line = line.gsub(/\[\[P\/GH\/AIS\/([A-Za-z0-9_ \-]+)\]\]/) {|s| "[[#{$1}]]"}
                if line == old_line
                  # Internal absolute link (4 levels) to subpage, no alternate title
                  line = line.gsub(/\[\[P\/([A-Za-z0-9]+)\/([A-Za-z0-9]+)\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_ \-]+)\]\]/) {|s| "[[P\\#{$1}\\#{$2}\\#{$3}\\#{$4}]]"}
                  if line == old_line
                    # Internal absolute link (3 levels) to subpage, no alternate title
                    line = line.gsub(/\[\[P\/([A-Za-z0-9]+)\/([A-Za-z]+)\/([A-Za-z0-9_ \-]+)\]\]/) {|s| "[[P\\#{$1}\\#{$2}\\#{$3}]]"}
                    if line == old_line
                      # Internal absolute link (2 levels) to subpage, no alternate title
                      line = line.gsub(/\[\[P\/([A-Za-z0-9]+)\/([A-Za-z0-9_ \-]+)\]\]/) {|s| "[[P\\#{$1}\\#{$2}]]"}
                      if line == old_line
                        # Internal absolute link (1 level) to subpage, no alternate title
                        line = line.gsub(/\[\[P\/([A-Za-z0-9_ \-]+)\]\]/) {|s| "[[P\\#{$1}]]"}
                        if line == old_line

                          # Internal link to subpage, no alternate title
                          old_line = line
                          line = line.gsub(/\[\[\/([A-Z][A-Za-z0-9_ \->]+)\]\]/) {|s| "[[#{current}#{$1}]]"}
                          
                          # Internal link to subpage, with alternate title
                          if line == old_line
                            line = line.gsub(/\[\[\/([A-Z][A-Za-z0-9]+)\|([a-zA-Z0-9 \/]*)\]\]/) {|s| "[[#{current}#{$1}|#{$2}]]"}
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
          
          #!!line = line.gsub(/\["([^"]*)"\]/) {|s| "[[#{parent}#{$1}]]"}
	  # Catch wikiwords with 2 or 3 parts
          #!!line = line.gsub(/(\s+)(([A-Z][a-z0-9]+){2,})(\s+|,)/) {|s| "#{$1}[[2ormoreparts#{$2}]]#{$4}"}
	  # No more need for explicit linebreaks
          line = line.gsub(/\[\[BR\]\]/) {|s| ""}

          # External Links
          line = line.gsub(/\[(http[^\s]+)\s+([^\]]+)\]/) {|s| "\"#{$2}\":#{$1}"}
          line = line.gsub(/\[(http[^\s]+)\]/) {|s| "#{$1}"}

          # Highlighting
          line = line.gsub(/'''''([^\s])/, '_*\1')
          line = line.gsub(/([^\s])'''''/, '\1*_')
          line = line.gsub(/'''([^\s])/, '*\1')
          line = line.gsub(/([^\s])'''/, '\1*')
          line = line.gsub(/''([^\s])/, '_*\1')
          line = line.gsub(/([^\s])''/, '\1*_')

          # code
          #line = line.gsub(/((^ [^\n]*\n)+)/m) { |s| "<pre>\n#{$1}</pre>\n" }
          #line = line.gsub(/(^\n^ .*?$)/m) { |s| "<pre><code>#{$1}" }
          #line = line.gsub(/(^ .*?\n)\n/m) { |s| "#{$1}</pre></code>\n" }
          line = line.gsub(/\{\{\{\s*$/) { |s| "<pre><code>" }
          #puts "BEFORE 4 #{line}"
          line = line.gsub(/^\s*\}\}\}\s*$/) { |s| "</code></pre>\n" }
          #puts "AFTER 4 #{line}"
          line = line.gsub(/\{\{\{/) { |s| "<code>" }
          line = line.gsub(/\}\}\}/) { |s| "</code>" }
          # Some silly leading whitespace.
          line = line.gsub(/<pre><code>\n/m) { |s| "<pre><code>" }        
          line = line.gsub('#!cplusplus', '')
          
          # Tables
          # Half-assed attempt
          # First strip off the table formatting
          line = line.gsub(/^\![^\|]*/, '')
          line = line.gsub(/^\{\|[^\|]*$/, '{|')
          # Now congeal the rows
          while( line.gsub!(/(\|-.*)\n(\|\w.*)$/m, '\1\2'))
          end
          # Now congeal the headers
          while( line.gsub!(/(\{\|.*)\n(\|\w.*)$/m, '\1\2'))
          end
          # format the headers properly
          while( line.gsub!(/(\{\|.*)\|([^_].*)$/, '\1|_. \2'))
          end
          # get rid of leading '{|'
          line = line.gsub(/^\{\|(.*)$/) { |s| "table(stdtbl)\n#{$1}|" }
          # get rid of leading '|-'
          line = line.gsub(/^\|-(.*)$/, '\1|')
          # get rid of trailing '|}'
          line = line.gsub(/^\|\}.*$/, '')
          # Internal Links
          line = line.gsub(/\[\[Image:([^\s]+)\]\]/) { |s| "!#{$1}!" }
          # Wiki page separator ':'
          while( line.gsub!(/(\[\[\s*\w+):(\w+)/, '\1_\2') )
          end

	  # throw away pragma statements
	  #puts line
          line = line.gsub(/^#pragma (.*)$/isu) {|s| ""}

          # Strip whitespace before bullets
          line = line.gsub(/^[ \t]+\*/, '*')
          
          # Strip whitespace before enumerations
          line = line.gsub(/^[ \t]+1\./, '#')

          new_text = new_text + line
        }
        #puts "FINAL #{new_text}"

        new_text
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
