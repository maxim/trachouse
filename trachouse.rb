# Trachouse v1.0.0
# Trac to LightHouse ticket converter
# Author: Shay Arnett http://shayarnett.com
# Email: shayarnett@gmail.com
# 
# 
# 
# Please read all commented sections, as most have something you will need to change directly below it
# 
# USE:
#
#   @tickets = populate_tickets # grabs all tickets from trac
#   import_tickets(@tickets) # import tickets to lighthouse
#   # profit
#   # you may want to inspect @tickets or only import a couple of tickets to verify format before processing all tickets



require 'Rubygems'
require 'hpricot'
require 'open-uri'
require 'net/http'
require 'activesupport'
require 'activeresource'
require 'lighthouse'
require "cgi"
require "pp"


class Ticket < ActiveResource::Base
  include Lighthouse
  # Lighthouse Account Name - Not your username
  Lighthouse.account = 'foo_bar'
  # Lighthouse api token 
  Lighthouse.token = 'xxxxxxxxx'

  def initialize

    @tickets = []
    @ticket = {}
    @ticket_list = []
    @useragent = 'Mozilla/5.0 (Macintosh; U; Intel Mac OS X; en-us) AppleWebKit/523.10.6 (KHTML, like Gecko) Version/3.0.4 Safari/523.10.6'

    # domain of your trac install
    @domain = 'trac.domain.com'

    # trac users e-mail - needed to pull full email address on ticket creator
    @username = 'tracuser@email.com'

    # trac users password
    @password = 'users_password'

    # @domain + this is the url for logging into track
    @login = '/login'

    # setup headers for grabbing cookie and tiket info
    @headers = {
      'Referer' => 'http://'+ @domain,
      'User-Agent' => @useragent
    }
    
    # setup connection
    @http = Net::HTTP.new(@domain,80)
    
    #setup project_ids and associated trac components
    # :project_id should be the lighthouse id of the project 
    #  you want to import the tickets to
    #
    # :components should be an array of the trac components you wish
    #  to import into this project
    #
    # project_1 = { :project_id => 1234,
    #               :components => ['Core','Module 1', 'etc']}
    # project_2 = { etc }
    
    merb_core = { :project_id => 7433,
                  :components => [ 'Merb',
                                   'Web Site',
                                   'Web site',
                                   'Documentation',
                                   'Routing',
                                   'Views']
                }

    merb_more = { :project_id => 7435,
                     :components => [ 'Generators',
                                      'Rspec Harness']
                   }

    merb_plugins = { :project_id => 7588,
                     :components => [ 'Plugin: DataMapper',
                                      'Plugin: ActiveRecord',
                                      'Plugins']
                   }
    # add all your project hashes to @projects
    #
    # this could have been combined with above, but tended to be less readable 
    # after adding a couple projects
    @projects = [ merb_core, merb_more, merb_plugins ]
  end

  def tag_prep(tags)
    returning tags do |tag|
      tag.collect! do |t|
        unless tag.blank?
          t.downcase!
          t.gsub! /(^')|('$)/, ''
          t.gsub! ' ','_'
          t.gsub! /[^a-z0-9 \-_@\!']/, ''
          t.strip!
          t
        end
      end
      tag.compact!
      tag.uniq!
    end
  end

  def get_project(ticket)
    project_id = nil
    @projects.each do |project|
      project_id = project[:project_id] if project[:components].include? ticket[:component]
      break unless project_id.nil?
    end
    return project_id
  end

  def build_ticket(doc, ticket_num)
    # this is all based on a pretty standard trac template
    # if you have done any customizing you will need to check your html
    # and change the necessary Hpricot searches to pull the correct data
    
    # build the base ticket
    ticket = { :title => (doc/"h2.summary").inner_html,
               :trac_url => '"Original Trac Ticket":http://' + @domain + '/ticket/' + ticket_num,
               :reporter => (doc/"//td[@headers='h_reporter']").inner_html,
               :priority => (doc/"//td[@headers='h_priority']").inner_html,
               :component => (doc/"//td[@headers='h_component']").inner_html,
               :status => (doc/"span.status").first.inner_html,
               :milestone => (doc/"//td[@headers='h_milestone']").inner_html,
               :description => (doc/"div.description").inner_html,
               :comments => [],
               :attachments => []
             }
             
    # clean up the description
    Hpricot(ticket[:description]).search("h3").remove
    ticket[:description].gsub!(/<\/?pre( class=\"wiki\")?>/,"@@@\n")
    ticket[:description].gsub!(/<\/?[^>]*>/, "")
    ticket[:description] = unescapeHTML(ticket[:description].gsub!(/\n\s*\n\s*\n/,"\n\n"))
    
    # gather and clean up the ticket changes
    changes = []
    (doc/"div.change").each do |c|
      changes << { :name => (c/"h3").inner_html, :comment => (c/"[.comment]|[.changes]").inner_html }
    end
    changes.each do |change|
      change[:name].gsub!(/<\/?[^>]*>/, "")
      change[:name].strip!
      change[:comment].gsub!(change[:name],"")
      change[:comment].gsub!(/<\/?[^>]*>/, "")
      change[:comment].gsub!(/\n\s*\n\s*\n/,"\n\n")
      ticket[:comments] << change[:name] + "\n@@@\n" + change[:comment] + "\n@@@\n"
    end
    ticket[:comments] = unescapeHTML(ticket[:comments].join("\n"))
    ticket[:comments].gsub!(/\((follow|in)[^\)]*\)/,'')
    
    # gather and cleanup the attachments
    (doc/"dl.attachments/dt/a").each do |a|
      ticket[:attachments] << "http://merb.devjavu.com#{a.attributes['href']}"
    end
    ticket[:attachments] = unescapeHTML(ticket[:attachments].join("\n"))
    
    # put together the final body
    ticket[:body] = [ "Originally posted on Trac by #{ticket[:reporter]}", ticket[:trac_url], ticket[:description], "h3. Trac Attachments", ticket[:attachments], "h3. Trac Comments", ticket[:comments]].join("\n")
    ticket[:tags] = [ticket[:priority],ticket[:component]]
    ticket[:tags] << "patch" if ticket[:title].match /patch/i
    ticket[:project_id] = get_project(ticket)
    return ticket
  end

  def unescapeHTML(string)
    # from CGI.rb - don't need the slow just the unescape
    string.gsub(/&(.*?);/n) do
      match = $1.dup
      case match
      when /\Aamp\z/ni           then '&'
      when /\Aquot\z/ni          then '"'
      when /\Agt\z/ni            then '>'
      when /\Alt\z/ni            then '<'
      when /\A#0*(\d+)\z/n       then
        if Integer($1) < 256
          Integer($1).chr
        else
          if Integer($1) < 65536 and ($KCODE[0] == ?u or $KCODE[0] == ?U)
            [Integer($1)].pack("U")
          else
            "&##{$1};"
          end
        end
      when /\A#x([0-9a-f]+)\z/ni then
        if $1.hex < 256
          $1.hex.chr
        else
          if $1.hex < 65536 and ($KCODE[0] == ?u or $KCODE[0] == ?U)
            [$1.hex].pack("U")
          else
            "&#x#{$1};"
          end
        end
      else
        "&#{match};"
      end
    end
  end

  def steal_cookie
    # get request to gather tokens needed to hijack cookie
    resp, data = @http.get2(@login, {'User-Agent' => @useragent})
    cookie = resp.response['set-cookie']
    data.match(/TOKEN\" value\=\"(\w+)\"/)
    url_params = "user=#{@username}&password=#{@password}&__FORM_TOKEN=#{$1}"
    @headers = {
      'Cookie' => cookie,
      'Referer' => 'http://' + @domain + @login,
      'Content-Type' => 'application/x-www-form-urlencoded'
    }
    # post to login and grab cookie for later
    resp, data = @http.post2(@login, url_params, @headers)
    cookie = resp.response['set-cookie']

    @headers = {
      'Cookie' => cookie
    }
  end

  def get_html_for_ticket(ticket)
    # change url in get2() if you go somewhere other than /ticket/1 to pull up ticket #1
    resp, data = @http.get2("/ticket/#{ticket}",@headers)
    Hpricot(unescapeHTML(data)) if resp.code == '200'
  end

  def create_ticket(trac_ticket)
    ticket = Lighthouse::Ticket.new(:project_id => trac_ticket[:project_id])
    ticket.title = trac_ticket[:title].to_s
    ticket.tags = tag_prep(trac_ticket[:tags])
    ticket.body = trac_ticket[:body].to_s
    ticket.save
  end
  
  def import_tickets(tickets)
    steal_cookie
    new_tickets = []
    tickets.each do |ticket|
      # grab the page for this ticket
      ticket_html = get_html_for_ticket(ticket)
      # pull data for ticket
      new_ticket = build_ticket(ticket_html,ticket)
      # add to @tickets[]
      new_tickets << new_ticket
    end
    
    # create and save to lighthouse
    new_tickets.each do |ticket|
      create_ticket(ticket)
    end
  end

  def populate_tickets
    # url should be the path to a trac report that shows you all tickets from
    # all components
    url = "/report/3"
    ticket_list = []
    resp, html = @http.get2(url, {'User-Agent' => @useragent})
    html = Hpricot(html)
    (html/".ticket").each do |a|
     a.inner_html =~ /\#(\d{1,3})/
     ticket_list << $1
    end
   ticket_list.sort
  end

end