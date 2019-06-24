[
    "socket",
    "thread",
    "json",
    "filecache",
    "rufus-scheduler",
	"uri",
    "net/http",
    "pp",
    "zlib",
    "rexml/document"
].each do |lib|
    begin
        require lib
    rescue LoadError
        system("gem install #{lib}")
        Gem.clear_paths
        retry
    end
end

include REXML
include Socket::Constants

GC.enable
GC.start

###############
## VARIABLES ##
###############
$TRY_LOGIN = false
$DBG = false

$/ = "\0"

$MASTER_CHAT = "PGO"

$SOCKETS = {
=begin
	socket_obj: chat_name
=end
}

$CHAT_INFO = {
=begin
	chat_name: {
		"socket": socket_obj,
		"bot": bot_obj,
		"last": last_poke,
	}
=end
}

$MISSING = [] # Array of Missing Pokemon

$JOIN_TRIES = {}

$queue = Queue.new
$SCHEDULER = Rufus::Scheduler.new
$CHAT_CACHE = FileCache.new('chat-cache', './.cache', 0, 2)

$LOGIN_FILE = 'xat_acct.json'
$BOT_INFO = JSON.parse(File.read($LOGIN_FILE))

$MISSING = File.read('missing_pokes.txt').downcase.strip.split(', ')
$MISSING.push("arceus")
$MISSING = $MISSING.to_set.to_a

$LAST_BUMP = nil
$LAST_LOGIN = 0

trap "SIGINT" do
	puts "Exiting"
	exit 130
end

def main
	$MASTER_CHAT.downcase!

	$SCHEDULER.every '1h', :first_at => Time.now + 2 do
		begin
			chats = JSON.parse(File.read('pgo_chats.json').downcase)
			$PGO_CHATS = chats.to_set.to_a.collect { |x| x.downcase }
			if $DBG
				$PGO_CHATS = []
			end
			if $TRY_LOGIN
				$PGO_CHATS = [$MASTER_CHAT]
			end
			$PGO_CHATS.delete($MASTER_CHAT)
			$PGO_CHATS.unshift($MASTER_CHAT)

			($PGO_CHATS - $SOCKETS.values).each do |chat|
				setupBot(chat)
			end
		rescue Exception => e
			puts e
			puts e.backtrace
		end
	end

	$SCHEDULER.every '5m' do
		logChatAsPGO($MASTER_CHAT)
		($queue.size).times do |i|
			setupBot($queue.pop)
		end
	end

	$SCHEDULER.every '3610s', :first_at => Time.now + 30 do
		$CHAT_INFO.each_value do |chat|
			if chat["bot"].instance_variable_get("@quit") != true && chat["socket"] != nil && $SOCKETS.key(chat["socket"])
				chat["bot"].sendPC(23232323, "!pgo use lure")
			end
		end
	end

	Thread.new do
		loop do
			input = gets("\n").chomp("\n")
			
			if !input.empty?
				if $CHAT_INFO[$MASTER_CHAT]["bot"] != nil
					if input[0] == "/"
						case input.split(" ")[0][1..-1].downcase
							when "join"
								setupBot(input.split(" ")[1], false, true)
							when "die"
								$SOCKETS.values.each { |sock| sock.close }
							when "lure"
								$CHAT_INFO.each_value do |chat|
									chat["bot"].sendPC(23232323, "!pgo use lure")
								end
							when "div"
								$CHAT_INFO[$MASTER_CHAT]["bot"].send("a", {
									"u" => $BOT_INFO["i"],
									"b" => 1,
									"k" => "Argue",
									"m" => "Bye",
									"p" => "INSERT_PASSWORD_HERE"
								})
							when "update"
								logChatAsPGO($MASTER_CHAT)
							when "login"
								login("flabbergast", "INSERT_PASSWORD_HERE")
							else
								puts "Unknown command string: [#{input}]"
						end
					else
						$CHAT_INFO[$MASTER_CHAT]["bot"].sendMessage(input)
					end
				end
			end
		end
	end

	begin 
		ready = IO.select($SOCKETS.values, [], [], 1)
		if ready == nil
			raise("Cycle - No SOCKETS")
		end
		ready.first.each do |socket|
			msg = socket.gets

			bot = $CHAT_INFO[$SOCKETS.key(socket)]["bot"]

			if msg.nil? || msg == nil
				bot.quit "MSG NIL"
				$SOCKETS.delete($SOCKETS.key(socket))
				break
			end

			msg.chomp!

			if msg[0, 1] == "<" && msg[-1, 1] == ">"
				begin
					packet = parse(msg)
					if packet.assoc("tag") != nil
						puts "#{msg}" if $DBG
						bot.handle(packet)
					end
				rescue Exception => e
					if e == "exit"
						exit 130
					end
					puts "Bad Packet: #{msg}\n#{e}"
					puts e.backtrace
				end
			end

			if bot.instance_variable_get("@quit") == true
				bot.quit "Quit = TRUE"
				$SOCKETS.delete($SOCKETS.key(socket))
			end
		end
		raise("Cycle")
	rescue IO::WaitReadable, Errno::EINTR, StandardError => e
		if e.message[/cycle/i]
			# Cycle done
		elsif e.class == IOError
			# Kille
		elsif e.class == NoMethodError
	        # Nothing.
	    else
	    	p e
	        p e.backtrace
	    end
		retry
	end
end

def findChat(name)
	if (chat = $CHAT_CACHE.get(name.downcase)) != nil && !(chat == 0 || chat == "0")
		return chat
	end
	logChatAsPGO(name.downcase)
	url = "https://xat.com/web_gear/chat/roomid.php?v2&d=#{name}"
	uri = URI(url)
	response = Net::HTTP.get(uri)
	if response[0] == "0"
		puts "Error getting id for chat #{name}: #{response}"
		return 0
	end
	js = JSON.parse(response)
	chat = js["id"]
	$CHAT_CACHE.set(name.downcase, chat)
	return chat
end

def logChatAsPGO(chat_name)
	puts "#{chat_name} has been logged as a PGO chat."
	begin
		retries ||= 0
		$PGO_CHATS |= [chat_name.downcase]
		$PGO_CHATS = $PGO_CHATS.to_set.to_a
		#puts chats.to_json
		File.open('pgo_chats.json', 'w') { |fo| fo.puts $PGO_CHATS.to_json.downcase }
	rescue Exception => e
		puts e
		puts e.backtrace
		retry if (retries += 1) <= 1
	end
end

def port(room)
    return 10000 if room.to_i == 8
    return room.to_i < 8 ? 9999 + room.to_i : 10007 + room.to_i % 32
end

def setupBot(chat, do_catch=false, force=false)
	chat = chat.downcase

	if $SOCKETS.has_key?(chat)
		puts "Bot is already started in #{chat}"
		return
	end


	if !force && $JOIN_TRIES.include?(chat) && Time.now.to_i - $JOIN_TRIES[chat] < 280
		time = Time.now.to_i - $JOIN_TRIES[chat]
		puts "Tried to join #{chat} #{time}s ago... aborting"
		return
	end

	Thread.new do
		puts "Starting bot for #{chat}, if it doesn't start something is borked..."
		chatid = findChat(chat)
		if chatid != 0
			bot = Bot.new(chatid, chat, do_catch)
			bot.start
		end
	end
end

def parse(packet)
	pdict = {}
	packet.scan(/(\w+)="(.*?)"/).each do |match|
		pdict[match[0]] = match[1]
	end
	tag = /<(\w+) /.match(packet).to_a[1].strip
	pdict["tag"] = tag
	return pdict
end

def getL5(i, p)
	if p == nil
		return 0
	end
	l5_info		= p.split("_")
	p_w			= Integer(l5_info[0])
	p_h			= Integer(l5_info[1])
	p_octaves	= l5_info[2]
	p_seed		= l5_info[3]
	t			= (Integer(i) % (p_w * p_h))
	p_x			= (t % p_w)
	p_y			= Integer((t / p_w).floor)
	f = IO.read("../100_100_5_"+p_seed+".txt").match(/#{p_x},#{p_y}:(\w+)/)
	
	return (f != nil)? f[1] : 0
end

def login(username, password)
	if Time.now.to_i - 3600 < $LAST_LOGIN && !$TRY_LOGIN
		return
	end
	$LAST_LOGIN = Time.now.to_i
	Thread.new do
		uri = URI.parse("https://mt.xat.com/web_gear/chat/mlogin2.php?v=1.9.2&m=7&sb=1&")
		request = Net::HTTP::Post.new(uri)
		request.content_type = "application/x-www-form-urlencoded"
		request["Pragma"] = "no-cache"
		request["Origin"] = "https://xat.com"
		request["Accept-Language"] = "en-US,en;q=0.8"
		request["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.36"
		request["Accept"] = "*/*"
		request["Cache-Control"] = "no-cache"
		request["Referer"] = "https://xat.com/login"
		request["Connection"] = "keep-alive"
		request.body = "json={\"M\": \"0\", \"P\": \"\", \"d\": \"INSERT_DEVICE_ID\", \"n\": \"#{username}\", \"nfy\": \"\", \"oi\": \"0\", \"p\": \"#{password}\", \"pt\": \"3\", \"t\": \"\"}"
		req_options = {
			use_ssl: uri.scheme == "https",
		}

		response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
			http.request(request)
		end
		if response.code != "200"
			$TRY_LOGIN = true
		else
			data = parse( JSON.parse(response.body)["v"] )
			File.open($LOGIN_FILE, 'w') do |fo|
				fo.puts( data.to_json )
				puts data
			end
			return data
		end
	end
end

class Bot
	def initialize(chat, chat_name, do_catch=false)
		@chat, @chat_name, @do_catch, @has_bot, @quit = chat, chat_name.downcase, do_catch, false, false

		@sent = false

		$JOIN_TRIES[@chat_name.downcase] = Time.now.to_i
	end

	def start
		@done = false

		ip, xp = "fwdelb00-1964376362.us-east-1.elb.amazonaws.com", port(@chat)

		@socket = Socket.new(AF_INET, SOCK_STREAM, 0)
		@socket.connect(Socket.pack_sockaddr_in(xp, ip))

		puts "[DEBUG] Connected to chat #{@chat_name} (#{@chat}) on [#{ip}:#{xp}]"

		$SOCKETS[@chat_name] = @socket
		$CHAT_INFO[@chat_name] = {
			"socket" => @socket,
			"bot" => self,
			"last" => nil
		}

		send("y", {
			"r" => $TRY_LOGIN ? 8 : @chat,
			"v" => 0,
			"u" => $BOT_INFO["i"],
			"z" => 8335799305056508195,
		})


	end

	def handle(packet)
		case packet["tag"]
			when "y"
				if $TRY_LOGIN
					send("v", {
						"p" => "$157746511",
						"n" => $BOT_INFO["n"]
					})
				elsif packet.has_key?("C")
					log "[CAPTCHA]: " + packet.to_s
					@quit = true
				else
					j2 = {
						"cb"	=> 0,

						"Y"		=> 2,

						"l5"	=> 0, #getL5(packet["i"], packet["p"]),
						"l4"	=> rand(2000),
						"l3"	=> rand(500),
						"l2"	=> 0,

						"y"		=> packet["i"],

						"p"		=> 0,
						"c"		=> @chat,
						"f"		=> 2,
					}
					$BOT_INFO.each do |key, value|
						key = case key
							when "k1"
								"k"
							when "i"
								"u"
							when "n", "tag", "k2"
								next
							else
								key
							end
						j2[key] = value
					end

					j2["N"] = $BOT_INFO["n"]
					j2["n"] = "flab·ber·gast"
					j2["a"] = 1306
					j2["h"] = ""

					j2["v"] = "2"

					send("j2", j2)
				end
			when "m", "p"
				if packet.has_key?("u") && @done
					if packet["tag"] == "m" && packet["u"].split("_")[0] == "23232323"
						match = /\[.*?\] https?:\/\/xat.com\/(.*?) - (.*?) \| (\d+) seconds \| ([\d.]+)% chance/.match(packet["t"]).to_a.values_at(1..-1)
						if match == []
							match = /A wild (.*?) has appeared! It will run away in (.*?) seconds. Use ''!pgo catch'' to catch it before it runs!\(Chance to catch: (.*?)%\)/.match(packet["t"]).to_a
							match[0] = @chat_name
						end
						if match == nil || match == [] || match.size == 1
							return
						end

						if $MISSING.include?(match[1].downcase) || match[1].split(" ")[0] == "(dmd)Shiny" || match[3].to_i < 10
							if $LAST_BUMP != "#{match[0].downcase}-#{match[1].downcase}"
								if match[0].index(" Arceus") != nil
									$CHAT_INFO[$MASTER_CHAT]["bot"].sendPC(23232323, "!bump Austin @#{match[0]} - #{match[1]}")
								end
								$CHAT_INFO[$MASTER_CHAT]["bot"].sendPC(23232323, "!bump Greg @#{match[0]} - #{match[1]}")
								$LAST_BUMP = "#{match[0].downcase}-#{match[1].downcase}"
							end
						end
						
						if $CHAT_INFO.include?(match[0].downcase) && $CHAT_INFO[match[0].downcase]["last"] == match[1].downcase
							return
						end
							
						log packet["t"]
						t = Time.now
						
						if $SOCKETS.has_key?(match[0].downcase)
							$CHAT_INFO[match[0].downcase]["last"] = match[1].downcase
							$CHAT_INFO[match[0].downcase]["bot"].sendPC(23232323, "!pgc")
						else
							setupBot(match[0].downcase, true)
							logChatAsPGO(match[0].downcase)
						end
					elsif packet["tag"] == "p" && packet["s"] == "2" && packet["t"].index($BOT_INFO["n"]) != nil
						log "[CATCH]: " + packet["t"]
					elsif packet["tag"] == "p"
						if !(packet["t"] == "This chat is already activated with a lure!" && packet["u"].split("_")[0] == "23232323")
							log "[PRIVATE]: " + String(packet)
						end

						if packet["u"].split("_")[0] != "23232323" || @chat_name == $MASTER_CHAT
							return
						end

						if packet["t"].include?("PokemonGO is not allowed in this chat, sorry.") || packet["t"].include?("You are not high enough rank to use this command, the minimum rank is ") || packet["t"].include?("You are not high enough rank to use the bot.") || packet["t"].include?("PokemonGO nie jest dozwolone w tym czacie, niestety.") || packet["t"].index("PokemonGO") == 0
							log "THIS IS NOT A PGO CHAT"
	                        $PGO_CHATS.delete(@chat_name)
	                        @quit = true
						elsif packet["t"].include?("Respond to this message within ")
							sendPC(23232323, "pls no")
						end
					end
				end
			#when "logout"
			#	log "Logout: " + String(packet)
			#	@quit = true
			when "v", "logout"
				log "Login Info: " + String(packet)
				if packet.has_key?("e")
					login("flabbergast", "INSERT_PASSWORD_HERE")
					@quit = true
					return
				end
				$BOT_INFO = {}
				packet.each do |k, v|
					$BOT_INFO[k] = v
				end
				File.open($LOGIN_FILE, 'w') { |fo| fo.puts $BOT_INFO.to_json }
				if self == $MASTER_BOT
					start()
				end
			when "i"
				#nada
			when "w"
				if packet["v"].split(" ")[0] != "0"
					send("w0", {})
				end
			when "dup"
				@quit = true
			when "u"
				if packet["u"].split("_")[0] == "23232323"
					@has_bot = true
				end
			when "done"
				@done = true
				if !@has_bot && @chat_name != $MASTER_CHAT
					log "THERE IS NO BOT"
					$PGO_CHATS.delete(@chat_name)
					@quit = true
				else
					if @do_catch
						sendPC(23232323, "!pgc")
						@sent = true
					end
				end
			when "z", "c"
				log packet
				if packet["tag"] == "z"
					send("z", {
						"d" => packet["u"].split("_")[0],
						"u" => $BOT_INFO["i"],
						"t" => "/a_not addded you as a friend"
					})
				end
			when "ldone"
				@quit = true
			else
				#unknown packet
				return
		end
	end

	def write(msg)
		@socket.send(msg + $/, 0)
		@socket.flush
	end

	def send(tag, attr)
		send = "<#{tag}"
		attr.each do |k, v|
			next if v.nil? || v == nil
			v = Text.new("#{v}", false, nil, false)
			send += " #{k}=\"#{v}\""
		end
		send += " />"
		log send if $DBG
		write send
	end

	def sendMessage(msg)
		send("m", {
			"t" => msg,
			"u" => $BOT_INFO["i"]
		})
	end

	def sendPC(id, msg)
		send("p", {
			"u" => id,
			"t" => msg,
			"s" => 2,
			"d" => $BOT_INFO["i"],
		})
	end

	def log(message)
		puts "[#{@chat_name}]: " + String(message)
	end
	
	def quit(msg)
		log "Quitting #{msg}"
		if @socket != nil
			@socket.close
		end
		if @chat_name == $MASTER_CHAT && !$TRY_LOGIN
			start()
			return
		end		
		if $PGO_CHATS.include?(@chat_name.downcase)
			$queue << @chat_name.downcase
		end
		@quit = true
	end
end

main()
