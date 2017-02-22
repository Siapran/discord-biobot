local discordia = require("discordia")
local client = discordia.Client()

local levenshtein = string.levenshtein

function string.starts(String,Start)
   return string.sub(String, 1, string.len(Start)) == Start
end

local function getUserMentionName( user )
	return "@" .. user.name .. "#" .. user.discriminator
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
			-- print("owner")
			return true 
		end
		local currentPerm = chan:getPermissionOverwriteFor(member)
		if currentPerm.allowedPermissions:has(perm) then 
			-- print("chan user override grant")
			return true 
		end
		if currentPerm.deniedPermissions:has(perm) then 
			-- print("chan user override deny")
			return false 
		end
		for role in member.roles do
			currentPerm = chan:getPermissionOverwriteFor(role)
			if currentPerm.allowedPermissions:has(perm) then 
				-- print("chan role override grant")
				return true 
			end
		end
		for role in member.roles do
			currentPerm = chan:getPermissionOverwriteFor(role)
			if currentPerm.deniedPermissions:has(perm) then 
				-- print("chan role override deny")
				return false 
			end
		end
		currentPerm = chan:getPermissionOverwriteFor(chan.guild.defaultRole)
		if currentPerm.allowedPermissions:has(perm) then 
			-- print("chan everyone override grant")
			return true 
		end
		if currentPerm.deniedPermissions:has(perm) then 
			-- print("chan everyone override deny")
			return false 
		end
		for role in member.roles do
			currentPerm = role.permissions
			if currentPerm.allowedPermissions:has(perm) then 
				-- print("user role grant")
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
			local sameAuthor = self.authors[message.author.id]
			if not (sameAuthor and sameAuthor.createdAt < message.createdAt) then
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

			res = self.messages:get("user", user)
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
			print("debugging:")
			for k,v in pairs(self.authors) do
				print("",k,v)
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
	if not chan.guild then print("Not in guild.") return end

	local member = fuzzySearch(chan.guild, arg)
	if not member then print("No such member.") return end

	local canRead = hasUserPermissionForChannel(message.author, chan, "readMessages")
	if not canRead then print("Unauthorized.") return end

	local res = findPostByMember(chan, member)
	if not res then print("No bio found.") return end

	local answer = "Found bio for user " .. member.user.mentionString
	if not message.channel.guild then
		answer = answer .. " on server `" .. chan.guild.name .. "`"
	end
	message.channel:sendMessage(answer)
	message.channel:sendMessage(res)
	print("bio delivered")

end

local function bio( message )
	print(message.author, message)
	local arg = string.match(message.content, "!bio (.+)%s*")
	if arg then
		for chan in client:getChannels("name", "bio") do
			_bio(message, chan, arg)
		end
	end
end



client:on("ready", function()
	print("Logged in as " .. client.user.username)
end)

client:on("messageCreate", function(message)
	if message.author == client.user then return end
	if message.channel.name == "bio" then
		local bio = getBio(message.channel)
		bio:addMessage(message)
		return
	end
	if string.starts(message.content, "!") then
		if message.content == "!ping" then
			message.channel:sendMessage("pong")
		end
		if string.starts(message.content, "!bio ") then
			bio(message)
		end
	end
end)

if args[2] then
	print("Starting bot with the following token:", args[2])
else
	print("Please provide a bot token via commandline arguments.")
	return
end

client:run(args[2])
