-- Discord: coressed | Roblox: keptlnside

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local PlayerData = require(Shared.PlayerData)
local CompetitionData = require(Shared.CompetitionData)
local ClubData = require(Shared.ClubData)
local DateUtil = require(Shared.Utilities.DateUtil)
local Format = require(Shared.Utilities.Format)

local NewsService = require(script.Parent.NewsService)
local PlayerModel = require(script.Parent.PlayerModel)

local AwardsService = {}

-- this is the shape we want for the team of the week
-- 1 gk, 4 defenders, 3 midfielders and 3 attackers
local XI = { GK = 1, DEF = 4, MID = 3, ATT = 3 }
local GroupOrder = { "GK", "DEF", "MID", "ATT" }

-- adds a players stats into whatever stats table we pass in
-- we keep the total rating so we can work out the average later
-- goals assists and clean sheets are stored separately for award scoring
local function bump(map, pid, rating, goals, assists, clean)
	local e = map[pid]
	if not e then
		e = { s = 0, n = 0, g = 0, a = 0, c = 0 }
		map[pid] = e
	end
	e.s += rating
	e.n += 1
	e.g += goals
	e.a += assists
	e.c += clean
end

-- tracks the same player in both weekly and monthly stats
-- this means the match system only needs to call one function
-- then the award system can use the data for different awards
function AwardsService.Track(career, pid, rating, goals, assists, clean)
	local world = career.world
	world.weekStats = world.weekStats or {}
	world.monthStats = world.monthStats or {}
	bump(world.weekStats, pid, rating, goals, assists, clean)
	bump(world.monthStats, pid, rating, goals, assists, clean)
end

-- gives the player the actual award and handles the rewards from it
-- award history is capped so it doesnt just keep growing forever
-- players at the users club also get extra morale
local function giveAward(career, player, name)
	player.awards = player.awards or {}
	table.insert(player.awards, 1, { s = career.world.season, d = career.world.day, n = name })
	while #player.awards > 20 do
		table.remove(player.awards)
	end
	player.rep = math.min(100, player.rep + 1)
	if player.club == career.manager.clubId then
		PlayerModel.AddMorale(player, 6)
	end
end

-- makes the player data that the ui actually needs
-- keeping this in one place means the different awards all use the same format
local function entryFor(world, p, value, extra)
	local club = p.club and world.clubs[p.club]
	local out = { id = p.id, name = PlayerModel.FullName(p), short = PlayerModel.ShortName(p), pos = p.pos, group = PlayerData.PositionGroup[p.pos], value = value, club = club and club.name or "Free Agent", clubId = p.club, primary = club and club.primary, secondary = club and club.secondary, short3 = club and club.short }
	if extra then
		for k, v in pairs(extra) do
			out[k] = v
		end
	end
	return out
end

-- takes all the candidates and builds the 11 players
-- each position group is sorted by value then we take the amount needed
local function pickXI(world, candidates)
	local byGroup = { GK = {}, DEF = {}, MID = {}, ATT = {} }
	for _, c in ipairs(candidates) do
		table.insert(byGroup[c.group], c)
	end
	local xi = {}
	for _, g in ipairs(GroupOrder) do
		table.sort(byGroup[g], function(a, b)
			return a.value > b.value
		end)
		for i = 1, XI[g] do
			if byGroup[g][i] then
				table.insert(xi, byGroup[g][i])
			end
		end
	end
	return xi
end

-- gets the league for a player through the club they currently play for
local function leagueOf(world, p)
	local club = p.club and world.clubs[p.club]
	return club and club.league
end

-- builds team of the week for every league
function AwardsService.TeamOfWeek(career)
	local world = career.world

	-- weekly stats are only needed until this function runs
	-- after processing them we reset them for the next week
	local stats = world.weekStats or {}
	world.weekStats = {}
	world.totw = world.totw or {}

	local byLeague = {}

	-- turn the raw weekly stats into candidates grouped by league
	for pid, e in pairs(stats) do
		local p = world.players[pid]
		if p and e.n > 0 then
			local league = leagueOf(world, p)
			if league then
				byLeague[league] = byLeague[league] or {}

				-- rating is the base value but goals assists and clean sheets
				-- can push a player higher so attackers and defenders can both compete
				local avg = e.s / e.n
				table.insert(byLeague[league], entryFor(world, p, avg + e.g * 0.15 + e.a * 0.08 + e.c * 0.1, { rating = math.floor(avg * 10 + 0.5) / 10, goals = e.g }))
			end
		end
	end

	local userClub = career.manager.clubId
	local userLeague = userClub and world.clubs[userClub].league

	-- process each league separately
	for league, list in pairs(byLeague) do
		-- we need at least 11 players to make a full xi
		if #list >= 11 then
			local xi = pickXI(world, list)
			world.totw[league] = { day = world.day, xi = xi }

			-- only notify the user about players from their own league
			if league == userLeague then
				local mine = {}

				for _, e in ipairs(xi) do
					if e.clubId == userClub then
						table.insert(mine, e.short)

						-- getting into totw gives a smaller morale boost
						local p = world.players[e.id]
						if p then
							PlayerModel.AddMorale(p, 3)
						end
					end
				end

				local def = CompetitionData.Get(league)

				-- only create inbox news if one of the users players actually got in
				if #mine > 0 then
					NewsService.Inbox(career, def.Name, "Team of the Week", table.concat(mine, ", ") .. (if #mine == 1 then " has" else " have") .. " been named in the " .. def.Name .. " Team of the Week.", "Award")
				end
			end
		end
	end
end

-- finds the best player from the stats collected during the month
function AwardsService.PlayerOfMonth(career)
	local world = career.world

	-- same thing as weekly stats, once this gets processed we start the next month fresh
	local stats = world.monthStats or {}
	world.monthStats = {}
	world.potm = world.potm or {}

	local y, m = DateUtil.ToCivil(world.day)
	local prevMonth = if m == 1 then 12 else m - 1
	local label = DateUtil.LongMonths[prevMonth] .. " " .. (if m == 1 then y - 1 else y)

	local best = {}

	-- find the best player for every league
	for pid, e in pairs(stats) do
		local p = world.players[pid]
		if p and e.n >= 3 then
			local league = leagueOf(world, p)

			if league then
				local avg = e.s / e.n

				-- rating is still the main part but goals assists and clean sheets
				-- give extra points depending on what the player did that month
				local score = avg + e.g * 0.12 + e.a * 0.07 + e.c * 0.05

				if not best[league] or score > best[league].value then
					best[league] = entryFor(world, p, score, { rating = math.floor(avg * 100 + 0.5) / 100, goals = e.g, assists = e.a, games = e.n, month = label })
				end
			end
		end
	end

	local userClub = career.manager.clubId
	local userLeague = userClub and world.clubs[userClub].league

	for league, e in pairs(best) do
		world.potm[league] = world.potm[league] or {}

		-- newest player of the month is always at the front
		table.insert(world.potm[league], 1, e)

		-- only keep the latest 9 entries
		while #world.potm[league] > 9 do
			table.remove(world.potm[league])
		end

		local def = CompetitionData.Get(league)
		local p = world.players[e.id]

		-- give the actual award to the player
		if p then
			giveAward(career, p, def.Short .. " Player of the Month (" .. label .. ")")
		end

		-- add general news for bigger leagues or the users league
		if def.Tier == 1 and (def.Size >= 16 or league == userLeague) or league == userLeague then
			NewsService.AddNews(career, "Award", e.name .. " is " .. def.Name .. " Player of the Month", e.club .. "'s " .. e.pos .. " averaged " .. string.format("%.2f", e.rating) .. " with " .. e.goals .. " goals in " .. label .. ".", { e.clubId })
		end

		-- send a direct inbox message when the winning player is in the users club
		if e.clubId == userClub then
			NewsService.Inbox(career, def.Name, "Player of the Month", e.name .. " has been named " .. def.Name .. " Player of the Month for " .. label .. ".", "Award")
		end
	end
end

-- gets the manager name from the club
-- USER means the manager is the actual player running the career
local function managerName(career, club)
	if club.managerId == "USER" then
		return career.manager.name, true
	end

	local m = club.managerId and career.world.managers[club.managerId]
	return if m then m.name else "Caretaker", false
end

-- manager of the month for every league
-- its based on points won in league games during the month
-- goal difference is also included when comparing teams
function AwardsService.ManagerOfMonth(career)
	local world = career.world

	local y, m = DateUtil.ToCivil(world.day)
	local prevMonth = if m == 1 then 12 else m - 1
	local prevYear = if m == 1 then y - 1 else y
	local fromDay = DateUtil.FromCivil(prevYear, prevMonth, 1)
	local label = DateUtil.LongMonths[prevMonth] .. " " .. prevYear

	local tally = {}

	-- go through every fixture and only count played league matches
	for _, f in pairs(world.fixtures) do
		if f.played and f.day >= fromDay and f.day < world.day and CompetitionData.Get(f.comp).Type == "League" then
			for side, cid in ipairs({ f.home, f.away }) do
				local gf = if side == 1 then f.hg else f.ag
				local ga = if side == 1 then f.ag else f.hg

				local t = tally[cid]

				if not t then
					t = { league = f.comp, w = 0, d = 0, l = 0, gf = 0, ga = 0, pts = 0 }
					tally[cid] = t
				end

				t.gf += gf
				t.ga += ga

				if gf > ga then
					t.w += 1
					t.pts += 3
				elseif gf == ga then
					t.d += 1
					t.pts += 1
				else
					t.l += 1
				end
			end
		end
	end

	local best = {}

	-- score each manager by points per game, goal difference and number of games played
	for cid, t in pairs(tally) do
		local games = t.w + t.d + t.l

		if games >= 2 then
			local score = t.pts / games * 10 + (t.gf - t.ga) * 0.1 + games * 0.01
			local cur = best[t.league]

			if not cur or score > cur.score then
				best[t.league] = { cid = cid, t = t, score = score }
			end
		end
	end

	world.motmManagers = world.motmManagers or {}

	local userClub = career.manager.clubId
	local userLeague = userClub and world.clubs[userClub] and world.clubs[userClub].league

	for league, b in pairs(best) do
		local club = world.clubs[b.cid]

		if club then
			local def = CompetitionData.Get(league)
			local name, isUser = managerName(career, club)
			local t = b.t

			local entry = { name = name, club = club.name, clubId = club.id, primary = club.primary, secondary = club.secondary, short3 = club.short, month = label, w = t.w, d = t.d, l = t.l, gf = t.gf, ga = t.ga, pts = t.pts, user = isUser }

			-- keep the latest manager of the month results for each league
			world.motmManagers[league] = world.motmManagers[league] or {}
			table.insert(world.motmManagers[league], 1, entry)

			while #world.motmManagers[league] > 9 do
				table.remove(world.motmManagers[league])
			end

			local record = t.w .. "W " .. t.d .. "D " .. t.l .. "L"

			-- if the user wins then add to their career award counter and inbox
			if isUser then
				career.manager.motmAwards = (career.manager.motmAwards or 0) + 1
				NewsService.Inbox(career, def.Name, "Manager of the Month", "Congratulations! You have been named " .. def.Name .. " Manager of the Month for " .. label .. " (" .. record .. ", " .. t.pts .. " points).", "Award")
			end

			-- only send global news for larger leagues or the users league
			if def.Tier == 1 and def.Size >= 16 or league == userLeague then
				NewsService.AddNews(career, "Award", name .. " named " .. def.Name .. " Manager of the Month", club.name .. " went " .. record .. " in " .. label .. ".", { club.id })
			end
		end
	end

	return best
end

-- manager of the year looks for the best overachiever
-- the main idea is to compare where a club was expected to finish
-- against where they actually finished
local function managerOfYear(career)
	local world = career.world
	local best

	for _, leagueId in ipairs(ClubData.LeagueOrder) do
		local def = CompetitionData.Get(leagueId)
		local comp = world.comps[leagueId]

		if comp and comp.table then
			-- rank teams by reputation to work out their expected position
			local byRep = table.clone(comp.teams)

			table.sort(byRep, function(a, b)
				return world.clubs[a].rep > world.clubs[b].rep
			end)

			local rows = {}

			-- copy the current table into a list so it can be sorted by position
			for _, cid in ipairs(comp.teams) do
				table.insert(rows, { id = cid, row = comp.table[cid] })
			end

			table.sort(rows, function(a, b)
				if a.row.pts ~= b.row.pts then
					return a.row.pts > b.row.pts
				end

				return (a.row.gf - a.row.ga) > (b.row.gf - b.row.ga)
			end)

			for pos, e in ipairs(rows) do
				local club = world.clubs[e.id]

				-- expected is based on club reputation compared to the other teams
				local expected = table.find(byRep, e.id) or pos

				local ppg = if e.row.p > 0 then e.row.pts / e.row.p else 0
				local trophies = 0

				-- count trophies won by this club during the current season
				for _, t in ipairs(club.trophies) do
					if t.season == world.season then
						trophies += 1
					end
				end

				-- lower leagues get reduced weighting so the award is more balanced
				local tierFactor = if def.Tier == 1 then 1 else 0.75 - (def.Tier - 2) * 0.1
				local sizeFactor = if def.Size >= 16 then 1 else 0.85

				-- overachievement matters a lot but points per game and trophies
				-- also help managers build up their final score
				local score = ((expected - pos) * 1.4 + ppg * 4 + (if pos == 1 then 5 else 0) + trophies * 3) * tierFactor * sizeFactor

				if not best or score > best.score then
					best = { score = score, club = club, pos = pos, expected = expected, league = def.Name, trophies = trophies }
				end
			end
		end
	end

	if not best then
		return nil
	end

	local name, isUser = managerName(career, best.club)

	-- make the text that explains why this manager won
	local why = "Finished " .. Format.Ordinal(best.pos) .. " in the " .. best.league .. " (tipped for " .. Format.Ordinal(best.expected) .. ")" .. (if best.trophies > 0 then " and won " .. best.trophies .. (if best.trophies > 1 then " trophies" else " trophy") else "")

	-- update the users career record if they won it
	if isUser then
		career.manager.moyAwards = (career.manager.moyAwards or 0) + 1
		NewsService.Inbox(career, "Football Association", "Manager of the Year!", "You have been crowned Manager of the Year. " .. why .. ".", "Award")
	end

	NewsService.AddNews(career, "Award", name .. " is Manager of the Year", best.club.name .. ": " .. why .. ".", { best.club.id })

	return { name = name, club = best.club.name, value = why, user = isUser }
end

-- runs all of the end of season player and manager awards
function AwardsService.Season(career)
	local world = career.world
	local season = world.season
	local record = { leagues = {}, ball = {} }

	local userClub = career.manager.clubId
	local ballCandidates = {}

	-- every league gets its own set of season awards
	for _, leagueId in ipairs(ClubData.LeagueOrder) do
		local def = CompetitionData.Get(leagueId)
		local entry = { league = leagueId }

		-- pots is player of the season
		-- scorer is golden boot
		-- glove is golden glove
		-- young is young player of the season
		local pots, potsScore, scorer, goals, glove, cleans, young, youngScore = nil, 0, nil, 0, nil, -1, nil, 0

		local candidates = {}

		-- look through every club in this league
		-- from there we can check every player in their squad
		for _, cid in ipairs(world.clubOrder) do
			local club = world.clubs[cid]

			if club.league == leagueId then
				for _, pid in ipairs(club.squad) do
					local p = world.players[pid]

					if p then
						local s = p.stats

						-- only players with enough rated games are considered
						if s.rated >= 10 then
							local avg = s.ratingSum / s.rated

							table.insert(candidates, entryFor(world, p, avg, { rating = math.floor(avg * 100 + 0.5) / 100 }))

							-- this score is used for the main player awards
							local score = avg + s.goals * 0.03 + s.assists * 0.02

							if s.rated >= 12 and score > potsScore then
								pots, potsScore = p, score
							end

							-- young player is still judged using the same performance score
							if p.age <= 21 and score > youngScore then
								young, youngScore = p, score
							end

							-- golden ball uses stricter minimum appearances
							-- and gives goals assists ovr and club reputation some influence
							if s.rated >= 15 then
								local tierFactor = if def.Tier == 1 then 1 else 0.85
								table.insert(ballCandidates, { p = p, score = (avg * 10 + s.goals * 0.6 + s.assists * 0.4 + p.ovr * 0.15) * tierFactor * (0.85 + club.rep / 600) })
							end
						end
					end
				end
			end
		end

		-- golden boot and golden glove use league competition stats
		-- this also supports players who moved clubs during the season
		local scorerApps = 0

		for _, p in pairs(world.players) do
			local ls = p.compStats and p.compStats[leagueId]

			-- fallback to normal stats for players without competition specific stats
			if not ls and not p.compStats and p.club and world.clubs[p.club] and world.clubs[p.club].league == leagueId then
				ls = p.stats
			end

			if ls then
				-- most goals wins the golden boot
				-- if goals are equal then fewer apps wins the tiebreak
				if ls.goals > goals or (ls.goals == goals and scorer and ls.apps < scorerApps) then
					scorer, goals, scorerApps = p, ls.goals, ls.apps
				end

				-- keep the clean sheet award limited to keepers with enough apps
				if p.pos == "GK" and ls.apps >= 10 and ls.clean > cleans then
					glove, cleans = p, ls.clean
				end
			end
		end

		-- handles storing an award in the season record
		-- also gives the player the award and sends an inbox message when needed
		local function award(p, title, field, value)
			if not p then
				return
			end

			entry[field] = { id = p.id, name = PlayerModel.FullName(p), club = p.club and world.clubs[p.club].name or "", value = value }

			giveAward(career, p, def.Short .. " " .. title)

			if p.club == userClub then
				NewsService.Inbox(career, def.Name, title, PlayerModel.FullName(p) .. " has won the " .. def.Name .. " " .. title .. " award!", "Award")
			end
		end

		-- add the main individual awards for this league
		award(pots, "Player of the Season", "pots", if pots then string.format("%.2f avg", pots.stats.ratingSum / pots.stats.rated) else nil)
		award(scorer, "Golden Boot", "boot", goals .. " goals")
		award(glove, "Golden Glove", "glove", cleans .. " clean sheets")
		award(young, "Young Player of the Season", "young", if young then string.format("%.2f avg", young.stats.ratingSum / young.stats.rated) else nil)

		-- build the team of the season using the same xi logic as team of the week
		local tots = pickXI(world, candidates)
		entry.tots = tots

		-- give every player in the tots their award
		for _, e in ipairs(tots) do
			local p = world.players[e.id]
			if p then
				giveAward(career, p, def.Short .. " Team of the Season")
			end
		end

		-- find the league champion from the final standings
		local standings = world.comps[leagueId] and world.comps[leagueId].table
		local best, bestPts = nil, -1

		if standings then
			for cid, row in pairs(standings) do
				if row.pts > bestPts then
					best, bestPts = cid, row.pts
				end
			end
		end

		if best then
			local club = world.clubs[best]
			local managerName

			-- the user gets their actual manager name
			if club.managerId == "USER" then
				managerName = career.manager.name
				NewsService.Inbox(career, def.Name, "Manager of the Season", "Congratulations! You have been named " .. def.Name .. " Manager of the Season.", "Award")
			else
				local m = club.managerId and world.managers[club.managerId]
				managerName = if m then m.name else "Caretaker"
			end

			entry.manager = { name = managerName, club = club.name }
		end

		-- only add wider news for the larger top tier competitions
		if def.Tier == 1 and def.Size >= 16 then
			if entry.pots then
				NewsService.AddNews(career, "Award", entry.pots.name .. " named " .. def.Name .. " Player of the Season", entry.pots.club .. " star finishes the campaign on " .. entry.pots.value .. ".", {})
			end

			if entry.boot then
				NewsService.AddNews(career, "Award", entry.boot.name .. " wins the " .. def.Name .. " Golden Boot", entry.boot.value .. " for " .. entry.boot.club .. ".", {})
			end
		end

		table.insert(record.leagues, entry)
	end

	-- sort the global golden ball candidates from highest score to lowest
	table.sort(ballCandidates, function(a, b)
		return a.score > b.score
	end)

	-- only store the top 3 golden ball players
	for i = 1, math.min(3, #ballCandidates) do
		local p = ballCandidates[i].p

		table.insert(record.ball, { id = p.id, name = PlayerModel.FullName(p), club = p.club and world.clubs[p.club].name or "", pos = p.pos, nat = PlayerData.NationName(p.nat), rank = i })

		-- all top 3 get a different award title
		giveAward(career, p, if i == 1 then "Golden Ball Winner" elseif i == 2 then "Golden Ball Runner-up" else "Golden Ball 3rd Place")

		if i == 1 then
			-- the actual winner gets a bigger reputation boost
			p.rep = math.min(100, p.rep + 5)

			NewsService.AddNews(career, "Award", PlayerModel.FullName(p) .. " wins the Golden Ball!", "The " .. PlayerData.NationName(p.nat) .. " " .. p.pos .. " of " .. record.ball[1].club .. " is crowned the best player in the world.", { p.club })

			-- notify the user directly if the winner is one of their players
			if p.club == userClub then
				NewsService.Inbox(career, "Golden Ball", "Golden Ball winner!", PlayerModel.FullName(p) .. " has won the Golden Ball as the best player in the world!", "Award")
			end
		end
	end

	-- manager of the year is calculated after the league season is finished
	record.managerYear = managerOfYear(career)

	-- save the finished award record under the current season
	world.awards[tostring(season)] = record

	-- keep only the latest 6 seasons so save data doesnt keep growing
	local keys = {}

	for k in pairs(world.awards) do
		table.insert(keys, tonumber(k))
	end

	table.sort(keys)

	while #keys > 6 do
		world.awards[tostring(table.remove(keys, 1))] = nil
	end
end

return AwardsService
