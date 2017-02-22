local discordia = require("discordia")
local client = discordia.Client()

local levenshtein = string.levenshtein

local function log( ... )
	print(os.date("[%x %X]"), ...)
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
			if currentPerm.allowedPermissions:has(perm) then 
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
			for message in self.messages:getAll("user", user) do
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
			return res
		end

		function bio:debug( )
			log("debugging:")
			for k,v in pairs(self.authors) do
				log("",k,v)
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
	if not member then log(chan.guild, "No such member.") return false end

	local canRead = hasUserPermissionForChannel(message.author, chan, "readMessages")
	if not canRead then log(chan.guild, "Unauthorized.") return false end

	local res = findPostByMember(chan, member)
	if not res then log(chan.guild, "No bio found.") return false end
	log(chan.guild, "Bio found.")

	local answer = "Bio for user " .. member.user.mentionString
	if not message.guild then
		answer = answer .. " on server \"" .. chan.guild.name .. "\""
	end
	answer = answer .. ":"
	message.channel:sendMessage(answer)
	message.channel:sendMessage(res)
	log("bio delivered")
	return true
end

local function bio( message )
	local arg = string.match(message.content, "!bio%s+(.+)%s*")
	if arg then
		local found = false
		if not message.guild then
			for chan in client:getChannels("name", "bio") do
				found = found or _bio(message, chan, arg)
			end
		else
			local chan = message.guild:getChannel("name", "bio")
			found = found or _bio(message, chan, arg)
		end
		if not found then
			message.channel:sendMessage("No bio found for \"" .. arg .. "\".")
		end
	else
		local fuzzyName = "\"" .. message.author.name:sub(1, 4):lower() .. "\""
		if message.member and message.member.nickname then
			fuzzyName = fuzzyName .. " or \"" .. message.member.nickname:sub(1, 4):lower() .. "\""
		end
		message.channel:sendMessage("Usage:"
			.. "\n\n\t`!bio target`"
			.. "\n\nWhere `target` is either:"
			.. "\n\tA mention (e.g. " .. message.author.mentionString .. ")"
			.. "\n\tThe first few letters of the target's nickname (e.g. " .. fuzzyName .. ")")
	end
end



client:on("ready", function()
	log("Logged in as " .. client.user.username)
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
		log(message.author, message, message.channel, message.guild)
		if message.content == "!ping" then
			message.channel:sendMessage("pong")
		end
		if message.content:startswith("!bio") then
			bio(message)
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
