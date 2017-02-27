local discordia = require("discordia")
local client = discordia.Client()

local levenshtein = string.levenshtein
local insert = table.insert

local function log( ... )
	print(os.date("[%x %X]"), ...)
end

local function embedFormat( description )
	return { embed = {
		description = description,
		color = discordia.Color(96, 64, 192).value,
	}}
end

-- thanks SinisterRectus for this wonder
local function fuzzySearch(guild, arg)
	local member = guild:getMember('id', arg)
	if member then return member end

	local bestMember
	local bestDistance = math.huge
	local lowered = arg:lower()

	for m in guild.members do
		if m.nickname and m.nickname:lower():startswith(lowered, true) then
			local d = levenshtein(m.nickname, arg)
			if d == 0 then
				return m
			elseif d < bestDistance then
				bestMember = m
				bestDistance = d
			end
		end
		if m.username and m.username:lower():startswith(lowered, true) then
			local d = levenshtein(m.username, arg)
			if d == 0 then
				return m
			elseif d < bestDistance then
				bestMember = m
				bestDistance = d
			end
		end
	end

	return bestMember
end

local function hasUserPermissionForChannel( user, chan, perm )
	if chan.guild then
		local member = user:getMembership(chan.guild)
		if not member then return false end
		if member == chan.guild.owner then
			-- log("owner")
			return true
		end
		local currentPerm = chan:getPermissionOverwriteFor(member)
		if currentPerm.allowedPermissions:has(perm) then
			-- log("chan user override grant")
			return true
		end
		if currentPerm.deniedPermissions:has(perm) then
			-- log("chan user override deny")
			return false
		end
		for role in member.roles do
			currentPerm = chan:getPermissionOverwriteFor(role)
			if currentPerm.allowedPermissions:has(perm) then
				-- log("chan role override grant")
				return true
			end
		end
		for role in member.roles do
			currentPerm = chan:getPermissionOverwriteFor(role)
			if currentPerm.deniedPermissions:has(perm) then
				-- log("chan role override deny")
				return false
			end
		end
		currentPerm = chan:getPermissionOverwriteFor(chan.guild.defaultRole)
		if currentPerm.allowedPermissions:has(perm) then
			-- log("chan everyone override grant")
			return true
		end
		if currentPerm.deniedPermissions:has(perm) then
			-- log("chan everyone override deny")
			return false
		end
		for role in member.roles do
			currentPerm = role.permissions
			if currentPerm:has(perm) then
				-- log("user role grant")
				return true
			end
		end
	end
	return false
end

local bios = {}

local function getBio( chan )
	local bio = bios[chan.id]
	if bio == nil then
		bio = {
			chan = chan,
			messages = discordia.Cache({}, class.__classes.Message, "id", chan),
			authors = {}
		}

		function bio:deleteMessage( message )
			self.messages:remove(message)
			local sameAuthor = self.authors[message.author.id]
			if sameAuthor then
				self.authors[message.author.id] = nil
				self:fetchUserBio(message.author)
			end
		end

		function bio:addMessage( message )
			-- log("Adding", message)
			local sameAuthor = self.authors[message.author.id]
			-- if sameAuthor then log("Existing bio found:", sameAuthor) end
			if not (sameAuthor and sameAuthor.createdAt > message.createdAt) then
				-- log("Replacing with newer bio.")
				self.authors[message.author.id] = message
			end
			if not (self.oldestMessage and self.oldestMessage.createdAt < message.createdAt) then
				self.oldestMessage = message
			end
			self.messages:add(message)
		end

		function bio:updateMessage( message )
			local sameAuthor = self.authors[message.author.id]
			if sameAuthor then
				self.authors[message.author.id] = message
			end
			self.messages:remove(message)
			self.messages:add(message)
		end

		function bio:getMessageById( messageId )
			return self.messages:get(messageId)
		end

		function bio:fetchHistory( )
			local count = 0
			if self.oldestMessage == nil then
				for message in self.chan:getMessageHistory() do
					self:addMessage(message)
					count = count + 1
				end
			else
				for message in self.chan:getMessageHistoryBefore(self.oldestMessage) do
					self:addMessage(message)
					count = count + 1
				end
			end
			return count
		end

		function bio:fetchUserBio( user )
			local res = self.authors[user.id]
			if res then return res end

			local res = nil
			for message in self.messages:getAll("author", user) do
				if not (sameAuthor and sameAuthor.createdAt > message.createdAt) then
					res = message
				end
			end
			if res then
				self.authors[user.id] = res
				return res
			end

			local count
			repeat
				count = self:fetchHistory()
				res = self.authors[user.id]
			until res ~= nil or count == 0
			if not res then self.authors[user.id] = nil end
			return res
		end

		function bio:debug( )
			log("debugging:")
			log("", self.oldestMessage)
			for k,v in pairs(self.authors) do
				log("",k,v)
			end
			for message in bio.messages:getAll() do
				log("", message)
			end
		end

		bios[chan.id] = bio
	end
	return bios[chan.id]
end

local function findPostByMember( chan, member )
	if not hasUserPermissionForChannel(member.user, chan, "readMessages") then return end
	local bio = getBio(chan)
	return bio:fetchUserBio(member.user)
end


client:on("messageUpdate", function( message )
	if message.channel.name == "bio" then
		local bio = getBio(message.channel)
		local cached = bio:getMessageById(message.id)
		if cached then
			bio:updateMessage(cached)
		end
	end
end)

client:on("messageDelete", function( message )
	if message.channel.name == "bio" then
		local bio = getBio(message.channel)
		local cached = bio:getMessageById(message.id)
		if cached then
			bio:deleteMessage(cached)
		end
	end
end)

client:on("messageUpdateUncached", function( channel, messageId )
	if channel.name == "bio" then
		local bio = getBio(channel)
		local cached = bio:getMessageById(messageId)
		if cached then
			cached = bio.chan:getMessage(messageId)
			bio:updateMessage(cached)
		end
	end
end)

client:on("messageDeleteUncached", function( channel, messageId )
	if channel.name == "bio" then
		local bio = getBio(channel)
		local cached = bio:getMessageById(messageId)
		if cached then
			bio:deleteMessage(cached)
		end
	end
end)

local function _bio( message, chan, arg )
	if not chan.guild then log("Not in guild.") return false end

	local member = nil
	for mention in message.mentionedUsers do
		member = chan.guild:getMember("id", mention.id)
	end
	member = member or fuzzySearch(chan.guild, arg)
	if not member then log(chan.guild, "No such member.") return false, member end

	local canRead = hasUserPermissionForChannel(message.author, chan, "readMessages")
	if not canRead then log(chan.guild, "Unauthorized.") return false, member end

	local res = findPostByMember(chan, member)
	if not res then log(chan.guild, "No bio found.") return false, member end
	log(chan.guild, "Bio found.")

	local answer = embedFormat(res.content)
	answer.embed.author = {
		name = member.name,
		icon_url = member.avatarUrl,
	}
	if not message.channel.guild then
		answer.embed.footer = {
			text = "On " .. chan.guild.name,
			icon_url = chan.guild.iconUrl,
		}
	end
	answer.embed.timestamp = os.date('!%Y-%m-%dT%H:%M:%S', res.createdAt)

	message.channel:sendMessage(answer)
	log("bio delivered")
	return true
end

local function bio( message )
	local arg = string.match(message.content, "!bio%s+(.+)%s*")
	if arg then
		local found = false
		local channels = {}
		local matchedSet = {}
		local matchedMembers = {}
		if not message.guild then
			for chan in client:getChannels("name", "bio") do
				channels[chan] = true
			end
		else
			local chan = message.guild:getChannel("name", "bio")
			channels[chan] = true
		end
		for chan,_ in pairs(channels) do
			local _found, member = _bio(message, chan, arg)
			found = found or _found
			if member then
				matchedSet[member.name] = true
			end
		end
		for name,_ in pairs(matchedSet) do
			insert(matchedMembers, name)
		end

		if not found then
			local matched = ""
			if #matchedMembers > 0 then
				matched = " (matched: " .. table.concat(matchedMembers, ", ") .. ")"
			end

			message.channel:sendMessage(embedFormat("No bio found for \"" .. arg .. "\"" .. matched .. "."))
		end
	else
		local fuzzyName = "\"" .. message.author.name:sub(1, 4):lower() .. "\""
		if message.member and message.member.nickname then
			fuzzyName = fuzzyName .. " or \"" .. message.member.nickname:sub(1, 4):lower() .. "\""
		end
		local answer = embedFormat(
			"\n\t`!bio target`"
				.. "\n\nWhere `target` is either:"
				.. "\n\tA mention (e.g. " .. message.author.mentionString .. ")"
				.. "\n\tThe first few letters of the target's nickname (e.g. " .. fuzzyName .. ")"
				.. "\n\nYou can issue commands privately to the bot by DM."
		)
		answer.embed.title = "Usage"
		message.channel:sendMessage(answer)
	end
end

local startingTime = os.date('!%Y-%m-%dT%H:%M:%S')
local version = io.popen("git show-ref --head --abbrev --hash"):read()
local hostname = io.popen("hostname"):read()

client:on("ready", function()
	log("Logged in as " .. client.user.username)
	bios = {} -- purge cache to enforce consistency
	client:setGameName("type !info for info")
end)

client:on("messageCreate", function(message)
	if message.author == client.user then return end
	if message.channel.name == "bio" then
		local bio = getBio(message.channel)
		bio:addMessage(message)
		-- bio:debug()
		return
	end
	if message.content:startswith("!") then
		if message.guild then
			log(message.author, message, message.channel, message.guild)
		else
			log("Private message.")
		end
		if message.content == "!ping" then
			message.channel:sendMessage("pong")
		end
		if message.content:startswith("!bio") then
			bio(message)
		end
		if message.content == "!info" then
			local answer = embedFormat(
				"A simple bot for fetching user bios from #bio channels."
			)
			answer.embed.fields = {
				{ name = "Usage", value = "Type `!bio` for help.", inline = true },
				{ name = "More info", value = "https://github.com/Siapran/discord-biobot", inline = true },
				{ name = "Bugs and suggestions", value = "https://github.com/Siapran/discord-biobot/issues", inline = true },
			}
			answer.embed.author = {
				name = client.user.name,
				icon_url = client.user.avatarUrl,
			}
			if hostname or version then
				local info = {}
				insert(info, hostname and ("Running on " .. hostname))
				insert(info, version and ("Version " .. version))
				answer.embed.footer = {
					text = table.concat(info, " | "),
				}
			end
			answer.embed.timestamp = startingTime
			message.channel:sendMessage(answer)
		end
		if message.author.id == client.owner.id and message.content == "!debug" then
			local biochan = message.guild and message.guild:getChannel("name", "bio")
			local bio = biochan and getBio(biochan)
			if bio then
				bio:debug()
			end
		end
	end
end)

if args[2] then
	log("Starting bot with the following token:", args[2])
else
	log("Please provide a bot token via commandline arguments.")
	return
end

client:run(args[2])
