--[[
    Chess AI Client v4.4 - Separate HUD Overlay
    Compact dropdown GUI + Original Game Sunfish + Visual Tracer

    Features
    --------
    * Uses ReplicatedStorage.Modules.SunfishHandler.Sunfish
    * Compact collapsible GUI
    * Difficulty profiles based on the game's own bot settings
    * Automatic adaptive mode: Easy/Normal/Hard/Nightmare escalation + committee
    * Vietnamese Thinking HUD generated from observable engine telemetry
    * Complexity-aware randomized human-like move delay
    * Analyze / Recommend mode (no automatic move)
    * Optional AutoMove
    * Highlights chosen piece + destination
    * Beam tracer for chosen move
    * Optional top-candidate tracers
    * EmergencyMove fallback copied from the game's own bot architecture
    * Live two-side piece HUD + material
    * Estimated win rate from Sunfish evaluation
    * Enemy best-response prediction + confidence
    * Shadow Sunfish state for non-sunfish matches when started at/near match start

    Notes
    -----
    - Best reliability: execute before a new match starts or at the very beginning.
    - In the game's built-in AI/sunfish mode, currentMatch.sunfishPos is reused read-only.
    - In other modes, the script maintains its own shadow Sunfish position from MovePiece traffic.
    - If injected mid-match and no synced position can be established, the GUI reports SYNC REQUIRED.

    Executor APIs used when available:
      getgc(), gethui()

    This script intentionally does NOT modify the game's Sunfish module/settings tables.
]]

--// ============================================================
--// SERVICES / MODULES
--// ============================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local Connections = ReplicatedStorage:WaitForChild("Connections")

local MovePieceRemote =
    Connections:FindFirstChild("MovePiece")
    or Connections:FindFirstChild("MovePie")

assert(MovePieceRemote, "[ChessAI] MovePiece remote not found")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local SunfishHandlerModule = Modules:WaitForChild("SunfishHandler")
local SunfishModule = SunfishHandlerModule:WaitForChild("Sunfish")

local Sunfish = require(SunfishModule)

--// ============================================================
--// CONFIG
--// ============================================================

local Config = {
    Expanded = false,

    Mode = "Automatic",

    AutoMove = false,
    Visual = true,
    Candidates = true,
    EnemyPrediction = true,

    -- Independent on-screen HUD elements.
    ShowPieceHUD = true,
    ShowEvalHUD = true,
    ShowMoveHUD = true,
    ShowThinkingHUD = true,

    -- Automatic mode dynamically escalates difficulty.
    AutomaticHumanDelay = true,
    AutomaticHesitationChance = 0.20,
    AutomaticCommittee = true,

    -- Enemy reply search uses a fraction of the selected mode's nodes
    -- so Nightmare does not perform two full 65k-node searches every turn.
    PredictionNodeFactor = 0.60,

    -- Time to show the selected move before AutoMove sends it.
    AutoMovePreviewDelay = 0.55,

    -- Keep tracer visible after recommendation.
    VisualLifetime = 4.0,

    -- Loop interval.
    PollRate = 0.12,
}

local ModeOrder = {
    "Automatic",
    "Baby",
    "Easy",
    "Normal",
    "Hard",
    "Nightmare",
}

--// ============================================================
--// UTILITY
--// ============================================================

local function DeepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}

    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy

    for k, v in pairs(value) do
        copy[DeepCopy(k, seen)] = DeepCopy(v, seen)
    end

    return copy
end

local function ClampNumber(v, fallback, minv, maxv)
    v = tonumber(v)

    if not v then
        return fallback
    end

    return math.clamp(v, minv, maxv)
end

local function GetBotSettings(botName)
    local Assets = ReplicatedStorage:FindFirstChild("Assets")
    local Bots = Assets and Assets:FindFirstChild("Bots")
    local Module = Bots and Bots:FindFirstChild(botName)

    if not Module or not Module:IsA("ModuleScript") then
        return nil
    end

    local ok, data = pcall(require, Module)

    if not ok or type(data) ~= "table" then
        return nil
    end

    local settings =
        data.settings
        or data.botSettings
        or (data.data and data.data.settings)

    if type(settings) ~= "table" then
        return nil
    end

    return DeepCopy(settings)
end

local function ApplyDefaults(settings)
    settings = settings or {}

    settings.nodes =
        ClampNumber(settings.nodes, 16384, 128, 500000)

    settings.depth =
        ClampNumber(settings.depth, 2, 1, 30)

    settings.worseMoveChance =
        ClampNumber(settings.worseMoveChance, 0, 0, 1)

    settings.lategameBonusDepth =
        ClampNumber(settings.lategameBonusDepth, 0, 0, 100)

    settings.pstParameters =
        type(settings.pstParameters) == "table"
        and settings.pstParameters
        or {}

    settings.overlookSettings =
        type(settings.overlookSettings) == "table"
        and settings.overlookSettings
        or {
            safezone = 3,
            targetDepths = {0, 1},
            strength = 1,
            smoothness = 1,
        }

    settings.evaluationSettings =
        type(settings.evaluationSettings) == "table"
        and settings.evaluationSettings
        or {}

    return settings
end

local function MakeProfiles()
    local easy =
        ApplyDefaults(
            GetBotSettings("BasicNoob")
        )

    local normal =
        ApplyDefaults(
            GetBotSettings("Wizard")
            or GetBotSettings("SolarisCultist")
        )

    local hard =
        ApplyDefaults(
            GetBotSettings("BuffNoob")
        )

    local nightmare =
        ApplyDefaults(
            GetBotSettings("Solaris")
        )

    local baby = DeepCopy(easy)

    baby.depth = 1
    baby.nodes = math.min(baby.nodes or 16384, 2500)
    baby.worseMoveChance = 0.72
    baby.relativeBadMoveCutoff = -450
    baby.lategameBonusDepth = 0

    easy.depth = math.min(easy.depth or 1, 2)
    easy.nodes = math.min(easy.nodes or 16384, 10000)

    normal.depth = math.max(normal.depth or 3, 3)
    normal.nodes = math.max(normal.nodes or 16384, 16384)

    hard.depth = math.max(hard.depth or 5, 5)
    hard.nodes = math.max(hard.nodes or 32768, 32768)

    nightmare.depth = math.max(nightmare.depth or 10, 10)
    nightmare.nodes = math.max(nightmare.nodes or 65536, 65536)
    nightmare.worseMoveChance = 0

    return {
        Baby = baby,
        Easy = easy,
        Normal = normal,
        Hard = hard,
        Nightmare = nightmare,
    }
end

local Profiles = MakeProfiles()


--// ============================================================
--// HUD / MATERIAL HELPERS
--// ============================================================

local MaterialValues = {
    P = 1,
    N = 3,
    B = 3,
    R = 5,
    Q = 9,
    K = 0,
}

local function PieceLetterFromObject(object)
    if typeof(object) ~= "Instance" then
        return "?"
    end

    local name = string.lower(object.Name)

    if string.find(name, "pawn", 1, true) then
        return "P"
    elseif string.find(name, "knight", 1, true) then
        return "N"
    elseif string.find(name, "bishop", 1, true) then
        return "B"
    elseif string.find(name, "rook", 1, true) then
        return "R"
    elseif string.find(name, "queen", 1, true) then
        return "Q"
    elseif string.find(name, "king", 1, true) then
        return "K"
    end

    return "?"
end

local function EmptyPieceCounts()
    return {
        P = 0,
        N = 0,
        B = 0,
        R = 0,
        Q = 0,
        K = 0,
        total = 0,
    }
end

local function CountTeamPieces(match, team)
    local counts = EmptyPieceCounts()

    if type(match) ~= "table" then
        return counts
    end

    local list =
        team
        and match.whitePieces
        or match.blackPieces

    if type(list) == "table" then
        for _, piece in pairs(list) do
            if type(piece) == "table"
                and piece.position
                and piece.team == team then

                local letter =
                    PieceLetterFromObject(
                        piece.object
                    )

                if counts[letter] ~= nil then
                    counts[letter] += 1
                    counts.total += 1
                end
            end
        end

        return counts
    end

    -- Fallback to currentMatch.contents.
    local source = match.contents

    if type(source) ~= "table" then
        return counts
    end

    if type(source[1]) == "table"
        and type(source[1][1]) == "table"
        and type(source[1][1][1]) == "table" then

        source = source[1]
    end

    for x = 1, 8 do
        local column = source[x]

        if type(column) == "table" then
            for y = 1, 8 do
                local piece = column[y]

                if type(piece) == "table"
                    and piece.team == team then

                    local letter =
                        PieceLetterFromObject(
                            piece.object
                        )

                    if counts[letter] ~= nil then
                        counts[letter] += 1
                        counts.total += 1
                    end
                end
            end
        end
    end

    return counts
end

local function MaterialScore(counts)
    local score = 0

    for piece, value in pairs(MaterialValues) do
        score += (counts[piece] or 0) * value
    end

    return score
end

local function FormatPieceCounts(counts, whiteSide)
    local icons =
        whiteSide
        and {
            Q = "♕",
            R = "♖",
            B = "♗",
            N = "♘",
            P = "♙",
        }
        or {
            Q = "♛",
            R = "♜",
            B = "♝",
            N = "♞",
            P = "♟",
        }

    return string.format(
        "%s%d  %s%d  %s%d  %s%d  %s%d",
        icons.Q,
        counts.Q or 0,
        icons.R,
        counts.R or 0,
        icons.B,
        counts.B or 0,
        icons.N,
        counts.N or 0,
        icons.P,
        counts.P or 0
    )
end

local function EstimateWinRate(score, mateState)
    if type(mateState) == "number" then
        if mateState > 0 then
            return 100
        elseif mateState < 0 then
            return 0
        end
    end

    score = tonumber(score) or 0

    -- Sunfish uses pawn ~= 100 evaluation units.
    -- This is intentionally labelled ESTIMATED, not a native probability.
    local win =
        100 / (
            1
            + math.exp(
                -score / 400
            )
        )

    if score > 0 then
        return math.clamp(
            math.floor(win + 0.5),
            51,
            99
        )
    elseif score < 0 then
        return math.clamp(
            math.floor(win + 0.5),
            1,
            49
        )
    end

    return 50
end

local function PredictionConfidence(results)
    if type(results) ~= "table"
        or #results == 0 then

        return 0
    end

    local final = results[#results]

    if type(final) ~= "table" then
        return 0
    end

    local s1 = tonumber(final.score1)
    local s2 = tonumber(final.score2)

    if not s1 then
        return 0
    end

    if not s2 or s2 <= -80000 then
        return 97
    end

    local gap =
        math.abs(s1 - s2)

    -- Bigger best-vs-second gap = more deterministic engine reply.
    return math.clamp(
        math.floor(
            28
            + gap / 3.2
        ),
        28,
        98
    )
end

--// ============================================================
--// MATCHCLIENT / CURRENT MATCH
--// ============================================================

local CachedMatchClient

local function FindMatchClient()
    if CachedMatchClient then
        local ok, match = pcall(function()
            return CachedMatchClient.currentMatch
        end)

        if ok and type(match) == "table" then
            return CachedMatchClient
        end
    end

    if type(getgc) ~= "function" then
        return nil
    end

    for _, object in ipairs(getgc(true)) do
        if type(object) == "table" then
            local currentMatch =
                rawget(object, "currentMatch")

            if type(currentMatch) == "table"
                and type(rawget(object, "processRound")) == "function"
                and type(rawget(object, "movePiece")) == "function" then

                CachedMatchClient = object
                return object
            end
        end
    end

    return nil
end

local function GetCurrentMatch()
    local client = FindMatchClient()

    if not client then
        return nil
    end

    local match =
        rawget(client, "currentMatch")

    if type(match) ~= "table" then
        return nil
    end

    if not match.boardExists or match.gameEnded then
        return nil
    end

    return match
end

local function GetLocalTeam(match)
    if type(match.players) == "table" then
        if match.players[true] == LocalPlayer
            and match.players[false] ~= LocalPlayer then

            return true
        end

        if match.players[false] == LocalPlayer
            and match.players[true] ~= LocalPlayer then

            return false
        end
    end

    -- Built-in AI matches often store the bot team explicitly.
    if type(match.botInfo) == "table"
        and type(match.botInfo.team) == "boolean" then

        return not match.botInfo.team
    end

    return nil
end

--// ============================================================
--// SUNFISH MOVE CONVERSION
--// ============================================================

local PromotionMap = {
    Pawn = "P",
    Knight = "N",
    Bishop = "B",
    Rook = "R",
    Queen = "Q",
    King = "K",
}

local ReversePromotionMap = {
    P = "Pawn",
    N = "Knight",
    B = "Bishop",
    R = "Rook",
    Q = "Queen",
    K = "King",
}

local function BoardPositionToNotation(pos)
    local x = pos[1]
    local y = pos[2]

    if type(x) ~= "number"
        or type(y) ~= "number" then
        return nil
    end

    if x < 1 or x > 8 or y < 1 or y > 8 then
        return nil
    end

    -- This is the exact orientation used by SunfishHandler.
    local file =
        string.char(8 - x + 97)

    return file .. tostring(y)
end

local function MatchMoveToSunfish(position, fromPos, toMove)
    if type(position) ~= "table"
        or type(fromPos) ~= "table"
        or type(toMove) ~= "table" then

        return nil
    end

    local fromNotation =
        BoardPositionToNotation(fromPos)

    local toNotation =
        BoardPositionToNotation(toMove)

    if not fromNotation or not toNotation then
        return nil
    end

    local player = position.player

    local fromLocation =
        Sunfish.notationToLocationNumber(
            fromNotation,
            player
        )

    local toLocation =
        Sunfish.notationToLocationNumber(
            toNotation,
            player
        )

    if not fromLocation or not toLocation then
        return nil
    end

    local promotionPiece

    if type(toMove.promote) == "table" then
        promotionPiece =
            PromotionMap[
                toMove.promote.pieceName
            ]
    end

    -- Find the exact generated move so castling,
    -- en-passant, doublemove, etc. retain engine metadata.
    local ok, generated =
        pcall(function()
            return position:genMoves()
        end)

    if not ok or type(generated) ~= "table" then
        return nil
    end

    for _, move in ipairs(generated) do
        if move[1] == fromLocation
            and move[2] == toLocation
            and move[4] == promotionPiece then

            return move
        end
    end

    return nil
end

local function SunfishMoveToBoard(move, position)
    if type(move) ~= "table"
        or not move[1]
        or not move[2]
        or type(position) ~= "table" then

        return nil
    end

    -- Sunfish stores moves in the current position's orientation.
    --
    -- notationToLocationNumber(notation, player):
    --   player == true  -> absolute location
    --   player == false -> 119 - absolute location
    --
    -- Therefore converting engine move -> physical board must undo
    -- that orientation:
    --
    --   player true  : use move index directly
    --   player false : use 119 - move index
    local function absoluteLocation(index)
        if position.player == false then
            return 119 - index
        end

        return index
    end

    local from =
        Sunfish.getPosition(
            absoluteLocation(move[1])
        )

    local to =
        Sunfish.getPosition(
            absoluteLocation(move[2])
        )

    if type(from) ~= "table"
        or type(to) ~= "table" then

        return nil
    end

    return {
        from = {from[1], from[2]},
        to = {to[1], to[2]},
        promotion = move[4],
        raw = move,
        enginePlayer = position.player,
    }
end

local function ResolveGameMove(match, sunfishMove, position, expectedTeam)
    local converted =
        SunfishMoveToBoard(
            sunfishMove,
            position
        )

    if not converted then
        return nil, "SUNFISH CONVERSION FAILED"
    end

    local fromPos = converted.from
    local toPos = converted.to

    local piece

    local okPiece, result =
        pcall(function()
            return match:getPiece(fromPos)
        end)

    if okPiece then
        piece = result
    end

    -- HARD GUARD:
    -- Never fabricate/fallback a move if the source square does not
    -- contain a real game piece. The old version did this and could
    -- send an impossible server move.
    if not piece then
        return nil,
            string.format(
                "NO PIECE AT %d,%d",
                fromPos[1],
                fromPos[2]
            )
    end

    if expectedTeam ~= nil
        and piece.team ~= expectedTeam then

        return nil,
            string.format(
                "ORIENTATION GUARD: SOURCE TEAM %s ~= TURN %s",
                tostring(piece.team),
                tostring(expectedTeam)
            )
    end

    local gameMoves

    local okMoves, movesResult =
        pcall(function()
            return piece:getMoves()
        end)

    if okMoves then
        gameMoves = movesResult
    end

    if type(gameMoves) ~= "table" then
        return nil, "piece:getMoves() FAILED"
    end

    -- Exact move lookup. No fake {x,y,moveOnly=true} fallback.
    for _, gameMove in pairs(gameMoves) do
        if type(gameMove) == "table"
            and gameMove[1] == toPos[1]
            and gameMove[2] == toPos[2] then

            if gameMove.promote
                and converted.promotion then

                gameMove.promote.pieceName =
                    ReversePromotionMap[
                        converted.promotion
                    ]
            end

            return {
                from = fromPos,
                move = gameMove,
                piece = piece,
                converted = converted,
            }
        end
    end

    return nil,
        string.format(
            "EXACT GAME MOVE NOT FOUND: %d,%d -> %d,%d",
            fromPos[1],
            fromPos[2],
            toPos[1],
            toPos[2]
        )
end

--// ============================================================
--// SHADOW POSITION FOR NON-SUNFISH MATCHES
--// ============================================================

local Shadow = {
    matchId = nil,
    position = nil,
    ready = false,
    reason = "NOT INITIALIZED",

    pendingKey = nil,
    pendingUntil = 0,
}

local function MoveKey(fromPos, toPos)
    return table.concat({
        tostring(fromPos and fromPos[1]),
        tostring(fromPos and fromPos[2]),
        tostring(toPos and toPos[1]),
        tostring(toPos and toPos[2]),
    }, ":")
end

local function ResetShadow(match)
    Shadow.matchId =
        match and match.id or nil

    Shadow.position = nil
    Shadow.ready = false
    Shadow.reason = "SYNC REQUIRED"

    Shadow.pendingKey = nil
    Shadow.pendingUntil = 0

    if not match then
        return
    end

    -- If the actual match already owns a Sunfish position,
    -- we do not need a shadow position.
    if match.mode == "sunfish"
        and type(match.sunfishPos) == "table" then

        Shadow.reason = "GAME SUNFISH"
        return
    end

    local atBeginning =
        (match.movesPGN == nil or match.movesPGN == "")
        and (
            match.round == nil
            or tonumber(match.round) == nil
            or tonumber(match.round) <= 2
        )

    if atBeginning then
        local ok, position =
            pcall(
                Sunfish.createPosition,
                Sunfish.initial
            )

        if ok and type(position) == "table" then
            Shadow.position = position
            Shadow.ready = true
            Shadow.reason = "SYNCED FROM START"
        else
            Shadow.reason = "CREATE POSITION FAILED"
        end
    else
        Shadow.reason =
            "MIDGAME: START NEXT MATCH"
    end
end

local function GetEnginePosition(match)
    if match.mode == "sunfish"
        and type(match.sunfishPos) == "table" then

        return match.sunfishPos, "GAME"
    end

    if Shadow.matchId ~= match.id then
        ResetShadow(match)
    end

    if Shadow.ready
        and type(Shadow.position) == "table" then

        return Shadow.position, "SHADOW"
    end

    return nil, Shadow.reason
end

local function ExtractMoveFromArgs(...)
    local args = table.pack(...)
    local positions = {}

    for i = 1, args.n do
        local value = args[i]

        if type(value) == "table"
            and type(value[1]) == "number"
            and type(value[2]) == "number"
            and value[1] >= 1
            and value[1] <= 8
            and value[2] >= 1
            and value[2] <= 8 then

            positions[#positions + 1] = value

            if #positions >= 2 then
                break
            end
        end
    end

    if #positions >= 2 then
        return positions[1], positions[2]
    end

    return nil, nil
end

local function ApplyConfirmedMoveToShadow(fromPos, toMove)
    if not Shadow.ready
        or type(Shadow.position) ~= "table" then
        return
    end

    local key =
        MoveKey(fromPos, toMove)

    if Shadow.pendingKey == key
        and os.clock() <= Shadow.pendingUntil then

        -- We already advanced the shadow immediately
        -- when AutoMove sent this move.
        Shadow.pendingKey = nil
        Shadow.pendingUntil = 0
        return
    end

    local move =
        MatchMoveToSunfish(
            Shadow.position,
            fromPos,
            toMove
        )

    if not move then
        Shadow.ready = false
        Shadow.reason =
            "DESYNC: MOVE CONVERSION FAILED"

        return
    end

    local ok, nextPos =
        pcall(function()
            return Shadow.position:move(move)
        end)

    if not ok
        or type(nextPos) ~= "table" then

        Shadow.ready = false
        Shadow.reason =
            "DESYNC: POSITION UPDATE FAILED"

        return
    end

    Shadow.position = nextPos
end

-- Listen to server-confirmed MovePiece traffic.
pcall(function()
    MovePieceRemote.OnClientEvent:Connect(
        function(...)
            local match =
                GetCurrentMatch()

            if not match then
                return
            end

            if Shadow.matchId ~= match.id then
                ResetShadow(match)
            end

            if match.mode == "sunfish" then
                return
            end

            local fromPos, toMove =
                ExtractMoveFromArgs(...)

            if fromPos and toMove then
                ApplyConfirmedMoveToShadow(
                    fromPos,
                    toMove
                )
            end
        end
    )
end)

--// ============================================================
--// SEARCH
--// ============================================================

local function CandidateMovesFromSearch(results)
    local output = {}

    if type(results) ~= "table"
        or #results == 0 then

        return output
    end

    local final =
        results[#results]

    if type(final) ~= "table" then
        return output
    end

    local seen = {}

    for rank = 1, 3 do
        local move =
            final["move" .. tostring(rank)]

        local score =
            final["score" .. tostring(rank)]

        if type(move) == "table" then
            local key =
                table.concat({
                    tostring(move[1]),
                    tostring(move[2]),
                    tostring(move[3]),
                    tostring(move[4]),
                }, ":")

            if not seen[key] then
                seen[key] = true

                output[#output + 1] = {
                    move = move,
                    score = score,
                    rank = rank,
                }
            end
        end
    end

    return output
end

local SetThinkingNarrative = function()
end

local function MoveIdentity(move)
    if type(move) ~= "table" then
        return "nil"
    end

    return table.concat({
        tostring(move[1]),
        tostring(move[2]),
        tostring(move[3]),
        tostring(move[4]),
    }, ":")
end

local function CandidateGap(results)
    if type(results) ~= "table"
        or #results == 0 then
        return 99999
    end

    local final = results[#results]

    if type(final) ~= "table" then
        return 99999
    end

    local s1 = tonumber(final.score1)
    local s2 = tonumber(final.score2)

    if not s1
        or not s2
        or s2 <= -80000 then
        return 99999
    end

    return math.abs(s1 - s2)
end

local function GetLegalMoveMetrics(match, team)
    local metrics = {
        legal = 0,
        captures = 0,
        tactical = 0,
        kingThreat = false,
    }

    if type(match) ~= "table"
        or type(team) ~= "boolean" then
        return metrics
    end

    local ownPieces =
        team
        and match.whitePieces
        or match.blackPieces

    local enemyPieces =
        team
        and match.blackPieces
        or match.whitePieces

    local kingPosition

    if type(ownPieces) == "table" then
        for _, piece in pairs(ownPieces) do
            if type(piece) == "table"
                and type(piece.position) == "table" then

                if PieceLetterFromObject(
                    piece.object
                ) == "K" then
                    kingPosition =
                        piece.position
                end

                local okMoves, moves =
                    pcall(function()
                        return piece:getMoves()
                    end)

                if okMoves
                    and type(moves) == "table" then

                    for _, move in pairs(moves) do
                        if type(move) == "table" then
                            metrics.legal += 1

                            local isTactical =
                                move.promote ~= nil
                                or move.castle ~= nil
                                or move.enpassant ~= nil
                                or move.capture ~= nil

                            local target
                            pcall(function()
                                target =
                                    match:getPiece({
                                        move[1],
                                        move[2],
                                    })
                            end)

                            if type(target) == "table"
                                and target.team ~= team then

                                metrics.captures += 1
                                isTactical = true
                            end

                            if isTactical then
                                metrics.tactical += 1
                            end
                        end
                    end
                end
            end
        end
    end

    -- Observable "king pressure": does any currently generated enemy
    -- move land on our king square? This is telemetry, not hidden reasoning.
    if kingPosition
        and type(enemyPieces) == "table" then

        for _, piece in pairs(enemyPieces) do
            if metrics.kingThreat then
                break
            end

            if type(piece) == "table"
                and type(piece.position) == "table" then

                local okMoves, moves =
                    pcall(function()
                        return piece:getMoves()
                    end)

                if okMoves
                    and type(moves) == "table" then

                    for _, move in pairs(moves) do
                        if type(move) == "table"
                            and move[1] == kingPosition[1]
                            and move[2] == kingPosition[2] then

                            metrics.kingThreat = true
                            break
                        end
                    end
                end
            end
        end
    end

    return metrics
end

local function RunSearchProfile(
    position,
    profileName
)
    local settings =
        DeepCopy(
            Profiles[profileName]
            or Profiles.Normal
        )

    local okSearch, results, mateState =
        pcall(
            Sunfish.search,
            position,
            settings.nodes,
            settings.depth,
            settings
        )

    if not okSearch then
        return nil, {
            error =
                "SEARCH ERROR ["
                .. tostring(profileName)
                .. "]: "
                .. tostring(results),
        }
    end

    if type(results) ~= "table"
        or #results == 0 then

        return nil, {
            error =
                "NO SEARCH RESULT ["
                .. tostring(profileName)
                .. "]",
            mateState = mateState,
        }
    end

    local okChoose,
        bestMove,
        score,
        rank =
        pcall(
            Sunfish.chooseMove,
            results,
            settings
        )

    if not okChoose
        or type(bestMove) ~= "table" then

        return nil, {
            error =
                "CHOOSE MOVE FAILED ["
                .. tostring(profileName)
                .. "]",
            mateState = mateState,
        }
    end

    return bestMove, {
        results = results,
        candidates =
            CandidateMovesFromSearch(results),

        score = score,
        rank = rank,
        mateState = mateState,
        settings = settings,
        selectedMode = profileName,
        candidateGap =
            CandidateGap(results),
    }
end

local function ChooseCommitteeResult(entries)
    local votes = {}
    local deepest = {
        Easy = 1,
        Normal = 2,
        Hard = 3,
        Nightmare = 4,
    }

    for _, entry in ipairs(entries) do
        if entry.move then
            local key =
                MoveIdentity(entry.move)

            local vote = votes[key]

            if not vote then
                vote = {
                    count = 0,
                    entries = {},
                }

                votes[key] = vote
            end

            vote.count += 1
            vote.entries[
                #vote.entries + 1
            ] = entry
        end
    end

    local bestVote

    for _, vote in pairs(votes) do
        if not bestVote
            or vote.count > bestVote.count then

            bestVote = vote
        elseif vote.count == bestVote.count then
            local function maxDepth(v)
                local d = 0

                for _, entry in ipairs(v.entries) do
                    d = math.max(
                        d,
                        deepest[
                            entry.mode
                        ] or 0
                    )
                end

                return d
            end

            if maxDepth(vote)
                > maxDepth(bestVote) then
                bestVote = vote
            end
        end
    end

    if not bestVote then
        return nil
    end

    local chosen

    for _, entry in ipairs(
        bestVote.entries
    ) do
        if not chosen
            or (
                deepest[entry.mode] or 0
            ) > (
                deepest[chosen.mode] or 0
            ) then

            chosen = entry
        end
    end

    return chosen,
        bestVote.count
end

local function AutomaticSearch(
    match,
    position
)
    local localTeam =
        GetLocalTeam(match)

    local metrics =
        GetLegalMoveMetrics(
            match,
            localTeam
        )

    SetThinkingNarrative(
        string.format(
            "Đang đọc thế cờ: %d nước hợp lệ, %d nước bắt quân%s.",
            metrics.legal,
            metrics.captures,
            metrics.kingThreat
                and " • Vua đang chịu áp lực"
                or ""
        ),
        "thinking"
    )

    task.wait()

    -- Easy is the scout. If the answer is obvious, there is no reason
    -- to spend Nightmare-level nodes.
    SetThinkingNarrative(
        "Easy đang quét nhanh để xem thế này có câu trả lời rõ ràng không...",
        "thinking"
    )

    local easyMove, easyInfo =
        RunSearchProfile(
            position,
            "Easy"
        )

    if not easyMove then
        return nil, easyInfo
    end

    local gap =
        easyInfo.candidateGap or 99999

    local complexity = 0

    if metrics.kingThreat then
        complexity += 4
    end

    if metrics.legal >= 24 then
        complexity += 2
    elseif metrics.legal >= 16 then
        complexity += 1
    end

    if metrics.tactical >= 4 then
        complexity += 2
    elseif metrics.tactical >= 1 then
        complexity += 1
    end

    if gap < 35 then
        complexity += 3
    elseif gap < 90 then
        complexity += 2
    elseif gap < 180 then
        complexity += 1
    end

    local easyScore =
        tonumber(easyInfo.score) or 0

    if math.abs(easyScore) < 90 then
        complexity += 1
    end

    -- Very forced positions with one clearly superior move are easier,
    -- unless the king is actually under pressure.
    if not metrics.kingThreat
        and gap > 300
        and metrics.legal <= 12 then

        complexity =
            math.max(
                0,
                complexity - 2
            )
    end

    complexity =
        math.clamp(
            complexity,
            0,
            9
        )

    local chosenMove = easyMove
    local chosenInfo = easyInfo
    local committeeText = "Easy"

    if complexity <= 2
        and not metrics.kingThreat then

        SetThinkingNarrative(
            string.format(
                "Thế khá rõ (gap %.0f). Easy đã đủ chắc, không cần nghĩ sâu hơn.",
                gap
            ),
            "decision"
        )

    elseif complexity <= 4
        and not metrics.kingThreat then

        SetThinkingNarrative(
            "Easy thấy vài phương án gần nhau. Normal vào kiểm tra lại.",
            "thinking"
        )

        local move, info =
            RunSearchProfile(
                position,
                "Normal"
            )

        if move then
            chosenMove = move
            chosenInfo = info
            committeeText =
                "Easy → Normal"
        end

    elseif complexity <= 6
        and not metrics.kingThreat then

        SetThinkingNarrative(
            "Thế có yếu tố chiến thuật. Chuyển Hard để kiểm tra sâu hơn.",
            "thinking"
        )

        local move, info =
            RunSearchProfile(
                position,
                "Hard"
            )

        if move then
            chosenMove = move
            chosenInfo = info
            committeeText =
                "Easy → Hard"
        end

    else
        SetThinkingNarrative(
            metrics.kingThreat
                and "Vua đang bị ép. Hard và Nightmare đang kiểm tra độc lập rồi bỏ phiếu."
                or "Các ứng viên quá sát. Hard và Nightmare đang kiểm tra độc lập rồi bỏ phiếu.",
            "thinking"
        )

        local hardMove, hardInfo =
            RunSearchProfile(
                position,
                "Hard"
            )

        SetThinkingNarrative(
            "Nightmare đang làm lượt kiểm tra cuối...",
            "thinking"
        )

        local nightmareMove,
            nightmareInfo =
            RunSearchProfile(
                position,
                "Nightmare"
            )

        local entries = {
            {
                mode = "Easy",
                move = easyMove,
                info = easyInfo,
            },
            {
                mode = "Hard",
                move = hardMove,
                info = hardInfo,
            },
            {
                mode = "Nightmare",
                move = nightmareMove,
                info = nightmareInfo,
            },
        }

        if Config.AutomaticCommittee then
            local consensus,
                votes =
                ChooseCommitteeResult(
                    entries
                )

            if consensus then
                chosenMove =
                    consensus.move

                chosenInfo =
                    consensus.info

                committeeText =
                    string.format(
                        "Easy/Hard/Nightmare • %d/3 đồng ý",
                        votes or 1
                    )
            end
        elseif nightmareMove then
            chosenMove = nightmareMove
            chosenInfo = nightmareInfo
            committeeText =
                "Nightmare"
        end

        if nightmareMove
            and not chosenMove then
            chosenMove = nightmareMove
            chosenInfo = nightmareInfo
        end
    end

    chosenInfo.automatic = {
        complexity = complexity,
        legalMoves = metrics.legal,
        captures = metrics.captures,
        tactical = metrics.tactical,
        kingThreat = metrics.kingThreat,
        scoutGap = gap,
        committee = committeeText,
    }

    SetThinkingNarrative(
        string.format(
            "Chốt %s • độ khó %d/9 • %s.",
            tostring(
                chosenInfo.selectedMode
            ),
            complexity,
            committeeText
        ),
        "decision"
    )

    return chosenMove,
        chosenInfo
end

local function SearchBestMove(match)
    local position, source =
        GetEnginePosition(match)

    if not position then
        return nil, {
            error = source or "NO POSITION",
        }
    end

    local bestMove, info

    if Config.Mode == "Automatic" then
        bestMove, info =
            AutomaticSearch(
                match,
                position
            )
    else
        SetThinkingNarrative(
            "Đang phân tích bằng "
            .. tostring(Config.Mode)
            .. "...",
            "thinking"
        )

        bestMove, info =
            RunSearchProfile(
                position,
                Config.Mode
            )
    end

    if not bestMove
        or not info then

        return nil,
            info
            or {
                error = "NO SEARCH RESULT",
            }
    end

    info.source = source
    info.position = position

    if Config.Mode ~= "Automatic" then
        SetThinkingNarrative(
            string.format(
                "%s đã chốt nước. Khoảng cách ứng viên đầu: %.0f điểm.",
                tostring(Config.Mode),
                tonumber(
                    info.candidateGap
                ) or 0
            ),
            "decision"
        )
    end

    return bestMove, info
end

local function RandomRange(minValue, maxValue)
    return minValue
        + math.random()
        * (maxValue - minValue)
end

local function AutomaticMoveDelay(
    info,
    usedEmergency
)
    if Config.Mode ~= "Automatic"
        or not Config.AutomaticHumanDelay then

        return Config.AutoMovePreviewDelay,
            false
    end

    local mode =
        info
        and info.selectedMode
        or "Normal"

    local ranges = {
        Easy = {0.25, 0.85},
        Normal = {0.55, 1.45},
        Hard = {1.00, 2.35},
        Nightmare = {1.65, 3.80},
    }

    local range =
        ranges[mode]
        or ranges.Normal

    local delay =
        RandomRange(
            range[1],
            range[2]
        )

    local automatic =
        info and info.automatic

    if automatic then
        if automatic.kingThreat then
            delay +=
                RandomRange(
                    0.35,
                    1.10
                )
        end

        if automatic.complexity >= 7 then
            delay +=
                RandomRange(
                    0.25,
                    0.90
                )
        end
    end

    if usedEmergency then
        delay +=
            RandomRange(
                0.25,
                0.80
            )
    end

    local hesitating =
        math.random()
        < Config.AutomaticHesitationChance

    if hesitating then
        delay +=
            RandomRange(
                1.00,
                3.10
            )
    end

    return math.clamp(
        delay,
        0.18,
        6.50
    ),
    hesitating
end

--// ============================================================
--// EXECUTABLE MOVE FALLBACK / ENEMY PREDICTION
--// ============================================================

local function FindEmergencyMove(
    match,
    position,
    expectedTeam
)
    if type(match) ~= "table"
        or type(position) ~= "table"
        or type(expectedTeam) ~= "boolean" then

        return nil, nil, nil
    end

    -- This mirrors the game's SunfishHandler.findEmergencyMove:
    -- scan every legal move produced by the GAME and score each one
    -- with Sunfish.evaluateMove().
    local pieces =
        expectedTeam
        and match.whitePieces
        or match.blackPieces

    if type(pieces) ~= "table" then
        return nil, nil, nil
    end

    local bestScore = -math.huge
    local bestSunfishMove
    local bestResolved

    for _, piece in pairs(pieces) do
        if type(piece) == "table"
            and piece.team == expectedTeam
            and type(piece.position) == "table" then

            local okMoves, gameMoves =
                pcall(function()
                    return piece:getMoves()
                end)

            if okMoves
                and type(gameMoves) == "table" then

                for _, gameMove in pairs(gameMoves) do
                    if type(gameMove) == "table" then
                        local sunfishMove =
                            MatchMoveToSunfish(
                                position,
                                piece.position,
                                gameMove
                            )

                        if sunfishMove then
                            local okEval, score =
                                pcall(
                                    Sunfish.evaluateMove,
                                    position,
                                    sunfishMove
                                )

                            if okEval
                                and type(score) == "number"
                                and score > bestScore then

                                bestScore = score
                                bestSunfishMove = sunfishMove

                                bestResolved = {
                                    from = {
                                        piece.position[1],
                                        piece.position[2],
                                    },

                                    move = gameMove,
                                    piece = piece,

                                    converted =
                                        SunfishMoveToBoard(
                                            sunfishMove,
                                            position
                                        ),
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    return bestSunfishMove,
        bestResolved,
        bestScore
end

local function ResolveOrEmergency(
    match,
    bestMove,
    info,
    expectedTeam
)
    local resolved, resolveError =
        ResolveGameMove(
            match,
            bestMove,
            info.position,
            expectedTeam
        )

    if resolved then
        return bestMove,
            resolved,
            false,
            nil,
            info.score
    end

    local emergencyMove,
        emergencyResolved,
        emergencyScore =
        FindEmergencyMove(
            match,
            info.position,
            expectedTeam
        )

    if emergencyMove
        and emergencyResolved then

        return emergencyMove,
            emergencyResolved,
            true,
            resolveError,
            emergencyScore
    end

    return nil,
        nil,
        false,
        resolveError
            or "NO EXECUTABLE MOVE",
        nil
end

local function PredictEnemyReply(
    position,
    ourMove,
    baseSettings
)
    if not Config.EnemyPrediction then
        return nil
    end

    if type(position) ~= "table"
        or type(ourMove) ~= "table" then

        return nil
    end

    local okPosition, nextPosition =
        pcall(function()
            return position:move(
                ourMove
            )
        end)

    if not okPosition
        or type(nextPosition) ~= "table" then

        return nil
    end

    local settings =
        DeepCopy(baseSettings)

    settings.nodes =
        math.max(
            4096,
            math.floor(
                (settings.nodes or 16384)
                * Config.PredictionNodeFactor
            )
        )

    local okSearch, results, mateState =
        pcall(
            Sunfish.search,
            nextPosition,
            settings.nodes,
            settings.depth,
            settings
        )

    if not okSearch
        or type(results) ~= "table"
        or #results == 0 then

        return nil
    end

    local okChoose,
        enemyMove,
        score,
        rank =
        pcall(
            Sunfish.chooseMove,
            results,
            settings
        )

    if not okChoose
        or type(enemyMove) ~= "table" then

        return nil
    end

    return {
        move = enemyMove,
        position = nextPosition,
        score = score,
        rank = rank,
        results = results,
        mateState = mateState,
        confidence =
            PredictionConfidence(
                results
            ),
    }
end

--// ============================================================
--// VISUAL TRACERS
--// ============================================================

local VisualFolder

local function ClearVisuals()
    if VisualFolder then
        VisualFolder:Destroy()
        VisualFolder = nil
    end
end

local function NewVisualFolder()
    ClearVisuals()

    VisualFolder =
        Instance.new("Folder")

    VisualFolder.Name =
        "ChessAI_Visual"

    VisualFolder.Parent = Workspace

    return VisualFolder
end

local function FindTile(x, y)
    local Board =
        Workspace:FindFirstChild("Board")

    if not Board then
        return nil
    end

    return Board:FindFirstChild(
        tostring(x) .. "," .. tostring(y)
    )
end

local function GetBasePart(object)
    if not object then
        return nil
    end

    if object:IsA("BasePart") then
        return object
    end

    return object:FindFirstChildWhichIsA(
        "BasePart",
        true
    )
end

local function MakeSelectionBox(part, transparency)
    if not part then
        return
    end

    local box =
        Instance.new("SelectionBox")

    box.Adornee = part
    box.LineThickness = 0.06
    box.SurfaceTransparency =
        transparency or 0.78

    box.Color3 =
        Color3.fromRGB(110, 170, 255)

    box.SurfaceColor3 =
        Color3.fromRGB(110, 170, 255)

    box.Parent = VisualFolder

    return box
end

local function MakePieceHighlight(pieceObject)
    if not pieceObject then
        return
    end

    local highlight =
        Instance.new("Highlight")

    highlight.Name = "ChosenPiece"

    highlight.Adornee = pieceObject

    highlight.FillColor =
        Color3.fromRGB(110, 170, 255)

    highlight.FillTransparency = 0.72

    highlight.OutlineColor =
        Color3.fromRGB(230, 240, 255)

    highlight.OutlineTransparency = 0.05

    highlight.DepthMode =
        Enum.HighlightDepthMode.AlwaysOnTop

    highlight.Parent = VisualFolder

    return highlight
end

local function MakeAttachment(part)
    local a =
        Instance.new("Attachment")

    a.Position =
        Vector3.new(
            0,
            part.Size.Y / 2 + 0.12,
            0
        )

    a.Parent = part

    return a
end

local function MakeBeam(partA, partB, style)
    if not partA or not partB then
        return
    end

    style = style or "candidate"

    local a0 = MakeAttachment(partA)
    local a1 = MakeAttachment(partB)

    a0.Parent = partA
    a1.Parent = partB

    local beam =
        Instance.new("Beam")

    beam.Attachment0 = a0
    beam.Attachment1 = a1

    beam.FaceCamera = true
    beam.Segments = 1

    if style == "primary" then
        beam.Width0 = 0.16
        beam.Width1 = 0.16

        beam.Transparency =
            NumberSequence.new(0.08)

        beam.Color =
            ColorSequence.new(
                Color3.fromRGB(
                    120,
                    185,
                    255
                )
            )

    elseif style == "enemy" then
        beam.Width0 = 0.12
        beam.Width1 = 0.12

        beam.Transparency =
            NumberSequence.new(0.18)

        beam.Color =
            ColorSequence.new(
                Color3.fromRGB(
                    255,
                    115,
                    105
                )
            )

    else
        beam.Width0 = 0.065
        beam.Width1 = 0.065

        beam.Transparency =
            NumberSequence.new(0.66)

        beam.Color =
            ColorSequence.new(
                Color3.fromRGB(
                    170,
                    190,
                    220
                )
            )
    end

    beam.Parent = VisualFolder

    return beam
end

local function DrawMovePath(boardMove, style)
    if not boardMove then
        return
    end

    local from = boardMove.from
    local to = boardMove.to

    if not from or not to then
        return
    end

    local fromTile =
        GetBasePart(
            FindTile(from[1], from[2])
        )

    local toTile =
        GetBasePart(
            FindTile(to[1], to[2])
        )

    if not fromTile or not toTile then
        return
    end

    -- Knight: draw an L path rather than a misleading diagonal.
    local dx =
        math.abs(to[1] - from[1])

    local dy =
        math.abs(to[2] - from[2])

    if (dx == 1 and dy == 2)
        or (dx == 2 and dy == 1) then

        local middleTile =
            GetBasePart(
                FindTile(
                    from[1],
                    to[2]
                )
            )

        if middleTile then
            MakeBeam(
                fromTile,
                middleTile,
                style
            )

            MakeBeam(
                middleTile,
                toTile,
                style
            )

            return
        end
    end

    MakeBeam(
        fromTile,
        toTile,
        style
    )
end

local VisualGeneration = 0

local VisualGeneration = 0

local function ShowRecommendation(
    match,
    actualMove,
    info,
    resolved,
    prediction
)
    if not Config.Visual then
        ClearVisuals()
        return
    end

    if not resolved then
        return
    end

    VisualGeneration += 1

    local generation =
        VisualGeneration

    NewVisualFolder()

    local from = resolved.from
    local destination =
        resolved.move

    local fromTile =
        GetBasePart(
            FindTile(from[1], from[2])
        )

    local toTile =
        GetBasePart(
            FindTile(
                destination[1],
                destination[2]
            )
        )

    MakeSelectionBox(
        fromTile,
        0.86
    )

    MakeSelectionBox(
        toTile,
        0.58
    )

    if resolved.piece
        and resolved.piece.object then

        MakePieceHighlight(
            resolved.piece.object
        )
    end

    DrawMovePath(
        resolved.converted,
        "primary"
    )

    -- Only show raw search candidates if the original best move
    -- was executable. During EmergencyMove the original candidate
    -- may be illegal according to the game's own getMoves().
    if Config.Candidates
        and not info.usedEmergency
        and type(info.candidates) == "table" then

        local drawn = 0

        for _, candidate in ipairs(
            info.candidates
        ) do
            if candidate.move ~= actualMove then
                local boardMove =
                    SunfishMoveToBoard(
                        candidate.move,
                        info.position
                    )

                if boardMove then
                    DrawMovePath(
                        boardMove,
                        "candidate"
                    )

                    drawn += 1

                    if drawn >= 2 then
                        break
                    end
                end
            end
        end
    end

    if Config.EnemyPrediction
        and prediction
        and prediction.move
        and prediction.position then

        local enemyBoardMove =
            SunfishMoveToBoard(
                prediction.move,
                prediction.position
            )

        if enemyBoardMove then
            DrawMovePath(
                enemyBoardMove,
                "enemy"
            )
        end
    end

    task.delay(
        Config.VisualLifetime,
        function()
            if generation
                == VisualGeneration then

                ClearVisuals()
            end
        end
    )
end

local BoardMoveText

--// ============================================================
--// GUI
--// ============================================================

local GuiParent

pcall(function()
    if gethui then
        GuiParent = gethui()
    end
end)

GuiParent =
    GuiParent
    or LocalPlayer:WaitForChild(
        "PlayerGui"
    )

local old =
    GuiParent:FindFirstChild(
        "ChessAICompact"
    )

if old then
    old:Destroy()
end

local ScreenGui =
    Instance.new("ScreenGui")

ScreenGui.Name = "ChessAICompact"
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.Parent = GuiParent

local Main =
    Instance.new("Frame")

Main.Name = "Main"
Main.Size =
    UDim2.fromOffset(286, 38)

Main.Position =
    UDim2.new(
        0.5,
        -143,
        0,
        72
    )

Main.BackgroundColor3 =
    Color3.fromRGB(18, 19, 23)

Main.BorderSizePixel = 0
Main.ClipsDescendants = true
Main.Parent = ScreenGui

Instance.new(
    "UICorner",
    Main
).CornerRadius =
    UDim.new(0, 10)

local Stroke =
    Instance.new("UIStroke")

Stroke.Color =
    Color3.fromRGB(53, 55, 64)

Stroke.Thickness = 1
Stroke.Parent = Main

local Header =
    Instance.new("TextButton")

Header.Name = "Header"

Header.Size =
    UDim2.new(1, 0, 0, 38)

Header.BackgroundTransparency = 1
Header.Text = ""
Header.AutoButtonColor = false
Header.Parent = Main

local Dot =
    Instance.new("Frame")

Dot.Size =
    UDim2.fromOffset(7, 7)

Dot.Position =
    UDim2.fromOffset(11, 15)

Dot.BackgroundColor3 =
    Color3.fromRGB(109, 205, 132)

Dot.BorderSizePixel = 0
Dot.Parent = Header

Instance.new(
    "UICorner",
    Dot
).CornerRadius =
    UDim.new(1, 0)

local HeaderTitle =
    Instance.new("TextLabel")

HeaderTitle.Position =
    UDim2.fromOffset(25, 0)

HeaderTitle.Size =
    UDim2.new(1, -62, 1, 0)

HeaderTitle.BackgroundTransparency = 1

HeaderTitle.Font =
    Enum.Font.GothamMedium

HeaderTitle.Text =
    "CHESS AI  •  READY"

HeaderTitle.TextSize = 11

HeaderTitle.TextColor3 =
    Color3.fromRGB(224, 226, 234)

HeaderTitle.TextXAlignment =
    Enum.TextXAlignment.Left

HeaderTitle.Parent = Header

local Arrow =
    Instance.new("TextLabel")

Arrow.Position =
    UDim2.new(1, -33, 0, 0)

Arrow.Size =
    UDim2.fromOffset(27, 38)

Arrow.BackgroundTransparency = 1

Arrow.Font =
    Enum.Font.GothamBold

Arrow.Text = "▼"
Arrow.TextSize = 11

Arrow.TextColor3 =
    Color3.fromRGB(145, 149, 164)

Arrow.Parent = Header

local Body =
    Instance.new("Frame")

Body.Position =
    UDim2.fromOffset(8, 42)

Body.Size =
    UDim2.new(1, -16, 0, 325)

Body.BackgroundTransparency = 1
Body.Visible = false
Body.Parent = Main

local ModeButton =
    Instance.new("TextButton")

ModeButton.Size =
    UDim2.new(1, 0, 0, 30)

ModeButton.BackgroundColor3 =
    Color3.fromRGB(27, 29, 35)

ModeButton.Text =
    "Mode   " .. Config.Mode .. "   ▾"

ModeButton.Font =
    Enum.Font.GothamMedium

ModeButton.TextSize = 11

ModeButton.TextColor3 =
    Color3.fromRGB(218, 220, 229)

ModeButton.AutoButtonColor = false
ModeButton.Parent = Body

Instance.new(
    "UICorner",
    ModeButton
).CornerRadius =
    UDim.new(0, 7)

local ModeList =
    Instance.new("Frame")

ModeList.Position =
    UDim2.fromOffset(0, 33)

ModeList.Size =
    UDim2.new(1, 0, 0, 0)

ModeList.BackgroundColor3 =
    Color3.fromRGB(23, 25, 31)

ModeList.BorderSizePixel = 0
ModeList.ClipsDescendants = true
ModeList.Visible = false
ModeList.ZIndex = 20
ModeList.Parent = Body

Instance.new(
    "UICorner",
    ModeList
).CornerRadius =
    UDim.new(0, 7)

local ModeLayout =
    Instance.new("UIListLayout")

ModeLayout.Padding =
    UDim.new(0, 2)

ModeLayout.Parent = ModeList

--// ============================================================
--// INDEPENDENT SCREEN HUD OVERLAYS
--// Not children of the compact settings dropdown.
--// ============================================================

local HUDRoot =
    Instance.new("Frame")

HUDRoot.Name = "HUDRoot"
HUDRoot.Size = UDim2.fromScale(1, 1)
HUDRoot.BackgroundTransparency = 1
HUDRoot.Active = false
HUDRoot.ZIndex = 5
HUDRoot.Parent = ScreenGui

local function NewHUDFrame(name, size, position, anchorPoint)
    local frame =
        Instance.new("Frame")

    frame.Name = name
    frame.Size = size
    frame.Position = position
    frame.AnchorPoint =
        anchorPoint or Vector2.new(0, 0)

    frame.BackgroundColor3 =
        Color3.fromRGB(17, 19, 24)

    frame.BackgroundTransparency = 0.14
    frame.BorderSizePixel = 0
    frame.ZIndex = 6
    frame.Parent = HUDRoot

    Instance.new(
        "UICorner",
        frame
    ).CornerRadius =
        UDim.new(0, 9)

    local stroke =
        Instance.new("UIStroke")

    stroke.Color =
        Color3.fromRGB(54, 58, 69)

    stroke.Transparency = 0.28
    stroke.Thickness = 1
    stroke.Parent = frame

    return frame
end

-- YOU / left ---------------------------------------------------

local YouHUD =
    NewHUDFrame(
        "YouPiecesHUD",
        UDim2.fromOffset(232, 54),
        UDim2.new(0, 14, 0, 76),
        Vector2.new(0, 0)
    )

local YouTitle =
    Instance.new("TextLabel")

YouTitle.Position =
    UDim2.fromOffset(9, 5)

YouTitle.Size =
    UDim2.new(1, -18, 0, 16)

YouTitle.BackgroundTransparency = 1
YouTitle.Font = Enum.Font.GothamBold
YouTitle.Text = "YOU"
YouTitle.TextSize = 10
YouTitle.TextColor3 =
    Color3.fromRGB(235, 238, 245)

YouTitle.TextXAlignment =
    Enum.TextXAlignment.Left

YouTitle.ZIndex = 7
YouTitle.Parent = YouHUD

local YouPieces =
    Instance.new("TextLabel")

YouPieces.Position =
    UDim2.fromOffset(9, 22)

YouPieces.Size =
    UDim2.new(1, -18, 0, 25)

YouPieces.BackgroundTransparency = 1
YouPieces.Font = Enum.Font.Gotham
YouPieces.Text =
    "♕1  ♖2  ♗2  ♘2  ♙8"

YouPieces.TextSize = 14
YouPieces.TextColor3 =
    Color3.fromRGB(220, 224, 234)

YouPieces.TextXAlignment =
    Enum.TextXAlignment.Left

YouPieces.ZIndex = 7
YouPieces.Parent = YouHUD

-- ENEMY / right ------------------------------------------------

local EnemyHUD =
    NewHUDFrame(
        "EnemyPiecesHUD",
        UDim2.fromOffset(232, 54),
        UDim2.new(1, -14, 0, 76),
        Vector2.new(1, 0)
    )

local EnemyTitle =
    Instance.new("TextLabel")

EnemyTitle.Position =
    UDim2.fromOffset(9, 5)

EnemyTitle.Size =
    UDim2.new(1, -18, 0, 16)

EnemyTitle.BackgroundTransparency = 1
EnemyTitle.Font = Enum.Font.GothamBold
EnemyTitle.Text = "ENEMY"
EnemyTitle.TextSize = 10
EnemyTitle.TextColor3 =
    Color3.fromRGB(170, 175, 190)

EnemyTitle.TextXAlignment =
    Enum.TextXAlignment.Right

EnemyTitle.ZIndex = 7
EnemyTitle.Parent = EnemyHUD

local EnemyPieces =
    Instance.new("TextLabel")

EnemyPieces.Position =
    UDim2.fromOffset(9, 22)

EnemyPieces.Size =
    UDim2.new(1, -18, 0, 25)

EnemyPieces.BackgroundTransparency = 1
EnemyPieces.Font = Enum.Font.Gotham
EnemyPieces.Text =
    "♟8  ♞2  ♝2  ♜2  ♛1"

EnemyPieces.TextSize = 14
EnemyPieces.TextColor3 =
    Color3.fromRGB(178, 183, 197)

EnemyPieces.TextXAlignment =
    Enum.TextXAlignment.Right

EnemyPieces.ZIndex = 7
EnemyPieces.Parent = EnemyHUD

-- Eval / top center --------------------------------------------

local EvalHUD =
    NewHUDFrame(
        "EvaluationHUD",
        UDim2.fromOffset(262, 59),
        UDim2.new(0.5, 0, 0, 74),
        Vector2.new(0.5, 0)
    )

local MaterialLabel =
    Instance.new("TextLabel")

MaterialLabel.Position =
    UDim2.fromOffset(8, 4)

MaterialLabel.Size =
    UDim2.new(1, -16, 0, 14)

MaterialLabel.BackgroundTransparency = 1
MaterialLabel.Font = Enum.Font.GothamMedium
MaterialLabel.Text = "MATERIAL  +0"
MaterialLabel.TextSize = 9
MaterialLabel.TextColor3 =
    Color3.fromRGB(171, 177, 194)

MaterialLabel.TextXAlignment =
    Enum.TextXAlignment.Center

MaterialLabel.ZIndex = 7
MaterialLabel.Parent = EvalHUD

local WinLabel =
    Instance.new("TextLabel")

WinLabel.Position =
    UDim2.fromOffset(8, 20)

WinLabel.Size =
    UDim2.new(1, -16, 0, 18)

WinLabel.BackgroundTransparency = 1
WinLabel.Font = Enum.Font.GothamBold
WinLabel.Text = "EST. WIN  --%   •   EVAL --"
WinLabel.TextSize = 10
WinLabel.TextColor3 =
    Color3.fromRGB(215, 220, 233)

WinLabel.TextXAlignment =
    Enum.TextXAlignment.Center

WinLabel.ZIndex = 7
WinLabel.Parent = EvalHUD

local WinBar =
    Instance.new("Frame")

WinBar.Position =
    UDim2.fromOffset(12, 43)

WinBar.Size =
    UDim2.new(1, -24, 0, 6)

WinBar.BackgroundColor3 =
    Color3.fromRGB(52, 55, 66)

WinBar.BorderSizePixel = 0
WinBar.ZIndex = 7
WinBar.Parent = EvalHUD

Instance.new(
    "UICorner",
    WinBar
).CornerRadius =
    UDim.new(1, 0)

local WinFill =
    Instance.new("Frame")

WinFill.Size =
    UDim2.new(0.5, 0, 1, 0)

WinFill.BackgroundColor3 =
    Color3.fromRGB(112, 174, 240)

WinFill.BorderSizePixel = 0
WinFill.ZIndex = 8
WinFill.Parent = WinBar

Instance.new(
    "UICorner",
    WinFill
).CornerRadius =
    UDim.new(1, 0)

-- Move + predicted reply / center -------------------------------

local MoveHUD =
    NewHUDFrame(
        "MovePredictionHUD",
        UDim2.fromOffset(320, 52),
        UDim2.new(0.5, 0, 0, 141),
        Vector2.new(0.5, 0)
    )

local AIMoveLabel =
    Instance.new("TextLabel")

AIMoveLabel.Position =
    UDim2.fromOffset(10, 5)

AIMoveLabel.Size =
    UDim2.new(1, -20, 0, 19)

AIMoveLabel.BackgroundTransparency = 1
AIMoveLabel.Font = Enum.Font.GothamMedium
AIMoveLabel.Text = "AI  •  --"
AIMoveLabel.TextSize = 10
AIMoveLabel.TextColor3 =
    Color3.fromRGB(126, 190, 245)

AIMoveLabel.TextXAlignment =
    Enum.TextXAlignment.Left

AIMoveLabel.ZIndex = 7
AIMoveLabel.Parent = MoveHUD

local EnemyMoveLabel =
    Instance.new("TextLabel")

EnemyMoveLabel.Position =
    UDim2.fromOffset(10, 27)

EnemyMoveLabel.Size =
    UDim2.new(1, -20, 0, 19)

EnemyMoveLabel.BackgroundTransparency = 1
EnemyMoveLabel.Font = Enum.Font.GothamMedium
EnemyMoveLabel.Text = "ENEMY  •  --"
EnemyMoveLabel.TextSize = 10
EnemyMoveLabel.TextColor3 =
    Color3.fromRGB(235, 135, 125)

EnemyMoveLabel.TextXAlignment =
    Enum.TextXAlignment.Left

EnemyMoveLabel.ZIndex = 7
EnemyMoveLabel.Parent = MoveHUD

-- Thinking / bottom center -------------------------------------

local ThinkingCard =
    NewHUDFrame(
        "ThinkingHUD",
        UDim2.fromOffset(430, 78),
        UDim2.new(0.5, 0, 1, -24),
        Vector2.new(0.5, 1)
    )

local ThinkingTitle =
    Instance.new("TextLabel")

ThinkingTitle.Position =
    UDim2.fromOffset(10, 6)

ThinkingTitle.Size =
    UDim2.new(1, -20, 0, 15)

ThinkingTitle.BackgroundTransparency = 1
ThinkingTitle.Font = Enum.Font.GothamBold
ThinkingTitle.Text = "NỘI TÂM • TELEMETRY"
ThinkingTitle.TextSize = 9
ThinkingTitle.TextColor3 =
    Color3.fromRGB(155, 166, 205)

ThinkingTitle.TextXAlignment =
    Enum.TextXAlignment.Left

ThinkingTitle.ZIndex = 7
ThinkingTitle.Parent = ThinkingCard

local ThinkingText =
    Instance.new("TextLabel")

ThinkingText.Position =
    UDim2.fromOffset(10, 23)

ThinkingText.Size =
    UDim2.new(1, -20, 0, 47)

ThinkingText.BackgroundTransparency = 1
ThinkingText.Font = Enum.Font.Gotham
ThinkingText.Text =
    "Chưa phân tích. Automatic sẽ tự chọn độ sâu theo thế cờ."

ThinkingText.TextSize = 9
ThinkingText.TextColor3 =
    Color3.fromRGB(190, 194, 207)

ThinkingText.TextWrapped = true
ThinkingText.TextXAlignment =
    Enum.TextXAlignment.Left

ThinkingText.TextYAlignment =
    Enum.TextYAlignment.Top

ThinkingText.ZIndex = 7
ThinkingText.Parent = ThinkingCard

local function RefreshHUDVisibility()
    YouHUD.Visible = Config.ShowPieceHUD
    EnemyHUD.Visible = Config.ShowPieceHUD
    EvalHUD.Visible = Config.ShowEvalHUD
    MoveHUD.Visible = Config.ShowMoveHUD
    ThinkingCard.Visible = Config.ShowThinkingHUD
end

SetThinkingNarrative =
    function(text, kind)
        text = tostring(text or "")
        ThinkingText.Text = text

        if kind == "decision" then
            ThinkingTitle.Text =
                "NỘI TÂM • QUYẾT ĐỊNH"

            ThinkingTitle.TextColor3 =
                Color3.fromRGB(
                    126,
                    190,
                    142
                )
        elseif kind == "hesitate" then
            ThinkingTitle.Text =
                "NỘI TÂM • ĐANG CHỜ"

            ThinkingTitle.TextColor3 =
                Color3.fromRGB(
                    221,
                    181,
                    105
                )
        elseif kind == "warning" then
            ThinkingTitle.Text =
                "NỘI TÂM • FALLBACK"

            ThinkingTitle.TextColor3 =
                Color3.fromRGB(
                    232,
                    142,
                    126
                )
        else
            ThinkingTitle.Text =
                "NỘI TÂM • TELEMETRY"

            ThinkingTitle.TextColor3 =
                Color3.fromRGB(
                    155,
                    166,
                    205
                )
        end

        task.wait()
    end

RefreshHUDVisibility()

local LastHUDWin = nil

local function ResetAnalysisHUD()
    LastHUDWin = nil

    WinLabel.Text =
        "EST. WIN  --%   •   EVAL --"

    WinFill.Size =
        UDim2.new(0.5, 0, 1, 0)

    AIMoveLabel.Text = "AI  •  --"
    EnemyMoveLabel.Text = "ENEMY  •  --"

    SetThinkingNarrative(
        "Chưa phân tích. Automatic sẽ tự tăng/giảm độ sâu theo thế cờ.",
        "thinking"
    )
end

local function UpdatePieceHUD(
    match,
    localTeam
)
    if type(match) ~= "table"
        or type(localTeam) ~= "boolean" then

        YouTitle.Text = "YOU"
        EnemyTitle.Text = "ENEMY"
        YouPieces.Text = "--"
        EnemyPieces.Text = "--"
        MaterialLabel.Text =
            "Material  --"

        return
    end

    local enemyTeam =
        not localTeam

    local you =
        CountTeamPieces(
            match,
            localTeam
        )

    local enemy =
        CountTeamPieces(
            match,
            enemyTeam
        )

    YouTitle.Text =
        "YOU • "
        .. (
            localTeam
            and "WHITE"
            or "BLACK"
        )

    EnemyTitle.Text =
        "ENEMY • "
        .. (
            enemyTeam
            and "WHITE"
            or "BLACK"
        )

    YouTitle.TextColor3 =
        localTeam
        and Color3.fromRGB(
            240,
            241,
            245
        )
        or Color3.fromRGB(
            155,
            160,
            174
        )

    EnemyTitle.TextColor3 =
        enemyTeam
        and Color3.fromRGB(
            240,
            241,
            245
        )
        or Color3.fromRGB(
            155,
            160,
            174
        )

    YouPieces.Text =
        FormatPieceCounts(
            you,
            localTeam
        )

    EnemyPieces.Text =
        FormatPieceCounts(
            enemy,
            enemyTeam
        )

    local delta =
        MaterialScore(you)
        - MaterialScore(enemy)

    MaterialLabel.Text =
        "MATERIAL  "
        .. (
            delta > 0
            and "+"
            or ""
        )
        .. tostring(delta)
end

local function SetAnalysisHUD(
    moveText,
    score,
    mateState,
    prediction,
    emergency
)
    local win =
        EstimateWinRate(
            score,
            mateState
        )

    LastHUDWin = win

    WinLabel.Text =
        string.format(
            "EST. WIN  %d%%   •   EVAL %+.2f",
            win,
            (tonumber(score) or 0) / 100
        )

    WinFill.Size =
        UDim2.new(
            win / 100,
            0,
            1,
            0
        )

    AIMoveLabel.Text =
        (
            emergency
            and "AI* • "
            or "AI  • "
        )
        .. tostring(moveText or "--")

    if prediction
        and prediction.move
        and prediction.position then

        local enemyText =
            BoardMoveText(
                prediction.move,
                prediction.position
            )

        EnemyMoveLabel.Text =
            string.format(
                "ENEMY  •  %s   •   %d%%",
                enemyText,
                prediction.confidence or 0
            )
    elseif Config.EnemyPrediction then
        EnemyMoveLabel.Text =
            "ENEMY  •  prediction unavailable"
    else
        EnemyMoveLabel.Text =
            "ENEMY  •  prediction OFF"
    end
end

local ModeOpen = false

local function CloseModeList()
    ModeOpen = false
    ModeList.Visible = false

    ModeList.Size =
        UDim2.new(1, 0, 0, 0)

    ModeButton.Text =
        "Mode   "
        .. Config.Mode
        .. "   ▾"
end

local function OpenModeList()
    ModeOpen = true
    ModeList.Visible = true

    ModeList.Size =
        UDim2.new(
            1,
            0,
            0,
            #ModeOrder * 26 + 8
        )

    ModeButton.Text =
        "Mode   "
        .. Config.Mode
        .. "   ▴"
end

for _, mode in ipairs(
    ModeOrder
) do
    local button =
        Instance.new("TextButton")

    button.Size =
        UDim2.new(1, 0, 0, 24)

    button.BackgroundTransparency = 1

    button.Text = mode

    button.Font =
        Enum.Font.Gotham

    button.TextSize = 10

    button.TextColor3 =
        Color3.fromRGB(
            190,
            193,
            207
        )

    button.ZIndex = 21
    button.Parent = ModeList

    button.MouseButton1Click:Connect(
        function()
            Config.Mode = mode
            CloseModeList()
        end
    )
end

ModeButton.MouseButton1Click:Connect(
    function()
        if ModeOpen then
            CloseModeList()
        else
            OpenModeList()
        end
    end
)

local function NewToggleRow(
    y,
    label,
    initial,
    callback
)
    local Row =
        Instance.new("Frame")

    Row.Position =
        UDim2.fromOffset(0, y)

    Row.Size =
        UDim2.new(1, 0, 0, 28)

    Row.BackgroundTransparency = 1
    Row.Parent = Body

    local Label =
        Instance.new("TextLabel")

    Label.Size =
        UDim2.new(1, -55, 1, 0)

    Label.BackgroundTransparency = 1

    Label.Font =
        Enum.Font.Gotham

    Label.Text = label

    Label.TextSize = 10

    Label.TextColor3 =
        Color3.fromRGB(
            184,
            187,
            199
        )

    Label.TextXAlignment =
        Enum.TextXAlignment.Left

    Label.Parent = Row

    local Toggle =
        Instance.new("TextButton")

    Toggle.Size =
        UDim2.fromOffset(38, 20)

    Toggle.Position =
        UDim2.new(
            1,
            -40,
            0.5,
            -10
        )

    Toggle.Text = ""
    Toggle.AutoButtonColor = false
    Toggle.Parent = Row

    Instance.new(
        "UICorner",
        Toggle
    ).CornerRadius =
        UDim.new(1, 0)

    local Knob =
        Instance.new("Frame")

    Knob.Size =
        UDim2.fromOffset(14, 14)

    Knob.Position =
        UDim2.fromOffset(3, 3)

    Knob.BackgroundColor3 =
        Color3.fromRGB(
            225,
            227,
            235
        )

    Knob.BorderSizePixel = 0
    Knob.Parent = Toggle

    Instance.new(
        "UICorner",
        Knob
    ).CornerRadius =
        UDim.new(1, 0)

    local state = initial

    local function Refresh()
        Toggle.BackgroundColor3 =
            state
            and Color3.fromRGB(
                72,
                103,
                183
            )
            or Color3.fromRGB(
                52,
                55,
                65
            )

        Knob.Position =
            state
            and UDim2.fromOffset(21, 3)
            or UDim2.fromOffset(3, 3)
    end

    Toggle.MouseButton1Click:Connect(
        function()
            state = not state
            Refresh()
            callback(state)
        end
    )

    Refresh()

    return function()
        return state
    end
end

NewToggleRow(
    36,
    "Auto Move",
    Config.AutoMove,
    function(v)
        Config.AutoMove = v
    end
)

NewToggleRow(
    62,
    "Visual tracer",
    Config.Visual,
    function(v)
        Config.Visual = v

        if not v then
            ClearVisuals()
        end
    end
)

NewToggleRow(
    88,
    "Candidate lines",
    Config.Candidates,
    function(v)
        Config.Candidates = v
    end
)

NewToggleRow(
    114,
    "Enemy prediction",
    Config.EnemyPrediction,
    function(v)
        Config.EnemyPrediction = v

        if not v then
            EnemyMoveLabel.Text =
                "ENEMY  •  prediction OFF"
        end
    end
)

NewToggleRow(
    140,
    "HUD • Piece count",
    Config.ShowPieceHUD,
    function(v)
        Config.ShowPieceHUD = v
        RefreshHUDVisibility()
    end
)

NewToggleRow(
    166,
    "HUD • Win / Eval",
    Config.ShowEvalHUD,
    function(v)
        Config.ShowEvalHUD = v
        RefreshHUDVisibility()
    end
)

NewToggleRow(
    192,
    "HUD • Moves",
    Config.ShowMoveHUD,
    function(v)
        Config.ShowMoveHUD = v
        RefreshHUDVisibility()
    end
)

NewToggleRow(
    218,
    "HUD • Thinking",
    Config.ShowThinkingHUD,
    function(v)
        Config.ShowThinkingHUD = v
        RefreshHUDVisibility()
    end
)


local AnalyzeButton =
    Instance.new("TextButton")

AnalyzeButton.Position =
    UDim2.fromOffset(0, 252)

AnalyzeButton.Size =
    UDim2.new(1, 0, 0, 29)

AnalyzeButton.BackgroundColor3 =
    Color3.fromRGB(44, 51, 70)

AnalyzeButton.Text =
    "ANALYZE / RECOMMEND"

AnalyzeButton.Font =
    Enum.Font.GothamMedium

AnalyzeButton.TextSize = 10

AnalyzeButton.TextColor3 =
    Color3.fromRGB(226, 229, 240)

AnalyzeButton.AutoButtonColor = false
AnalyzeButton.Parent = Body

Instance.new(
    "UICorner",
    AnalyzeButton
).CornerRadius =
    UDim.new(0, 7)

local Status =
    Instance.new("TextLabel")

Status.Position =
    UDim2.fromOffset(0, 286)

Status.Size =
    UDim2.new(1, 0, 0, 18)

Status.BackgroundTransparency = 1

Status.Font =
    Enum.Font.Code

Status.Text =
    "READY"

Status.TextSize = 9

Status.TextColor3 =
    Color3.fromRGB(126, 190, 142)

Status.TextXAlignment =
    Enum.TextXAlignment.Left

Status.TextTruncate =
    Enum.TextTruncate.AtEnd

Status.Parent = Body

local function SetStatus(text, bad)
    text = tostring(text)

    HeaderTitle.Text =
        "CHESS AI  •  "
        .. string.upper(
            string.sub(text, 1, 20)
        )

    Status.Text = text

    local color =
        bad
        and Color3.fromRGB(
            220,
            115,
            115
        )
        or Color3.fromRGB(
            126,
            190,
            142
        )

    Status.TextColor3 = color
    Dot.BackgroundColor3 = color
end

local function SetExpanded(value)
    Config.Expanded = value
    Body.Visible = value

    Arrow.Text =
        value and "▲" or "▼"

    CloseModeList()

    TweenService:Create(
        Main,
        TweenInfo.new(
            0.16,
            Enum.EasingStyle.Quad,
            Enum.EasingDirection.Out
        ),
        {
            Size =
                value
                and UDim2.fromOffset(
                    286,
                    330
                )
                or UDim2.fromOffset(
                    286,
                    38
                )
        }
    ):Play()
end

Header.MouseButton1Click:Connect(
    function()
        SetExpanded(
            not Config.Expanded
        )
    end
)

-- Drag from header.
local Dragging = false
local DragStart
local MainStart

Header.InputBegan:Connect(
    function(input)
        if input.UserInputType
                == Enum.UserInputType.MouseButton1
            or input.UserInputType
                == Enum.UserInputType.Touch then

            Dragging = true
            DragStart = input.Position
            MainStart = Main.Position
        end
    end
)

UserInputService.InputChanged:Connect(
    function(input)
        if not Dragging then
            return
        end

        if input.UserInputType
                == Enum.UserInputType.MouseMovement
            or input.UserInputType
                == Enum.UserInputType.Touch then

            local delta =
                input.Position - DragStart

            Main.Position =
                UDim2.new(
                    MainStart.X.Scale,
                    MainStart.X.Offset
                        + delta.X,

                    MainStart.Y.Scale,
                    MainStart.Y.Offset
                        + delta.Y
                )
        end
    end
)

UserInputService.InputEnded:Connect(
    function(input)
        if input.UserInputType
                == Enum.UserInputType.MouseButton1
            or input.UserInputType
                == Enum.UserInputType.Touch then

            Dragging = false
        end
    end
)

--// ============================================================
--// ANALYZE / AUTOMOVE
--// ============================================================

local Thinking = false
local LastAutoRound = nil
local LastMatchId = nil

BoardMoveText = function(move, position)
    local converted =
        SunfishMoveToBoard(
            move,
            position
        )

    if not converted then
        return "?"
    end

    local letter = "?"

    if type(position) == "table"
        and type(position.board) == "string"
        and type(move) == "table"
        and type(move[1]) == "number" then

        local char =
            string.sub(
                position.board,
                move[1],
                move[1]
            )

        if char
            and char ~= ""
            and char ~= "."
            and char ~= " " then

            letter =
                string.upper(char)
        end
    end

    return string.format(
        "%s %d,%d → %d,%d",
        letter,
        converted.from[1],
        converted.from[2],
        converted.to[1],
        converted.to[2]
    )
end

local function Analyze(
    autoSend
)
    if Thinking then
        return false
    end

    local match =
        GetCurrentMatch()

    if not match then
        SetStatus(
            "NO ACTIVE MATCH",
            true
        )

        return false
    end

    local localTeam =
        GetLocalTeam(match)

    if localTeam == nil then
        SetStatus(
            "UNKNOWN TEAM",
            true
        )

        return false
    end

    UpdatePieceHUD(
        match,
        localTeam
    )

    if match.activeTeam ~= localTeam then
        SetStatus(
            "OPPONENT TURN",
            false
        )

        return false
    end

    Thinking = true

    SetStatus(
        "THINKING • "
        .. string.upper(
            Config.Mode
        ),
        false
    )

    local ok, bestMove, info =
        pcall(
            SearchBestMove,
            match
        )

    if not ok then
        Thinking = false

        SetStatus(
            "SEARCH CRASH: "
            .. tostring(bestMove),
            true
        )

        return false
    end

    if not bestMove then
        Thinking = false

        SetStatus(
            info
                and info.error
                or "NO MOVE",
            true
        )

        return false
    end

    -- Resolve the engine's best move against the GAME'S legal moves.
    -- If it cannot be mapped, use the same emergency architecture
    -- as the original SunfishHandler instead of retrying forever.
    local actualMove,
        resolved,
        usedEmergency,
        originalResolveError,
        executableScore =
        ResolveOrEmergency(
            match,
            bestMove,
            info,
            localTeam
        )

    if not actualMove
        or not resolved then

        Thinking = false

        SetStatus(
            originalResolveError
                or "NO EXECUTABLE MOVE",
            true
        )

        return false
    end

    info.usedEmergency =
        usedEmergency

    info.originalBestMove =
        bestMove

    info.executableScore =
        executableScore

    if usedEmergency then
        SetThinkingNarrative(
            "Nước Sunfish chọn không khớp move hợp lệ của game. Tôi đã bỏ nước đó và chuyển sang EmergencyMove tốt nhất.",
            "warning"
        )
    end

    local prediction

    if Config.EnemyPrediction then
        SetStatus(
            usedEmergency
                and "EMERGENCY • PREDICTING"
                or "PREDICTING ENEMY",
            false
        )

        SetThinkingNarrative(
            usedEmergency
                and "Đã có nước fallback hợp lệ. Đang mô phỏng phản đòn tốt nhất của đối thủ..."
                or "Đã chốt nước của mình. Đang mô phỏng phản đòn tốt nhất của đối thủ...",
            "thinking"
        )

        prediction =
            PredictEnemyReply(
                info.position,
                actualMove,
                info.settings
            )
    end

    local text =
        BoardMoveText(
            actualMove,
            info.position
        )

    SetAnalysisHUD(
        text,
        executableScore
            or info.score,
        info.mateState,
        prediction,
        usedEmergency
    )

    ShowRecommendation(
        match,
        actualMove,
        info,
        resolved,
        prediction
    )

    if usedEmergency then
        SetStatus(
            "EMERGENCY • " .. text,
            false
        )
    else
        SetStatus(
            "AI: "
            .. text
            .. " • "
            .. string.upper(
                Config.Mode == "Automatic"
                    and (
                        "AUTO/"
                        .. tostring(
                            info.selectedMode
                            or "?"
                        )
                    )
                    or Config.Mode
            ),
            false
        )
    end

    if not autoSend then
        Thinking = false
        return true
    end

    local moveDelay,
        hesitating =
        AutomaticMoveDelay(
            info,
            usedEmergency
        )

    if Config.Mode == "Automatic" then
        if hesitating then
            SetThinkingNarrative(
                string.format(
                    "Ừ, tôi biết nên đi %s rồi... nhưng chưa muốn đánh ngay. Chờ thêm %.1fs.",
                    text,
                    moveDelay
                ),
                "hesitate"
            )
        else
            SetThinkingNarrative(
                string.format(
                    "Đã quyết định %s. Độ khó hiện tại: %s • chờ %.1fs trước khi đi.",
                    text,
                    tostring(
                        info.selectedMode
                        or "Normal"
                    ),
                    moveDelay
                ),
                "decision"
            )
        end
    end

    task.wait(
        moveDelay
    )

    -- Re-check turn after search/prediction/preview.
    local liveMatch =
        GetCurrentMatch()

    if not liveMatch
        or liveMatch.id ~= match.id
        or liveMatch.activeTeam ~= localTeam then

        Thinking = false
        return false
    end

    local liveClient =
        FindMatchClient()

    if not liveClient then
        Thinking = false

        SetStatus(
            "MATCHCLIENT LOST",
            true
        )

        return false
    end

    -- Re-resolve against the live game state. The opponent cannot
    -- legally move during our turn, but this protects against local
    -- board transitions / promotion UI / delayed bookkeeping.
    local liveResolved, liveResolveError =
        ResolveGameMove(
            liveMatch,
            actualMove,
            info.position,
            localTeam
        )

    if not liveResolved then
        -- If the emergency move itself became stale, calculate one
        -- more legal fallback against the live board.
        local emergencyMove,
            emergencyResolved,
            emergencyScore =
            FindEmergencyMove(
                liveMatch,
                info.position,
                localTeam
            )

        if emergencyMove
            and emergencyResolved then

            actualMove = emergencyMove
            liveResolved = emergencyResolved
            usedEmergency = true

            SetThinkingNarrative(
                "Board thay đổi nhẹ trước lúc click. Đã tính lại EmergencyMove để không gửi nước stale.",
                "warning"
            )

            text =
                BoardMoveText(
                    actualMove,
                    info.position
                )

            SetAnalysisHUD(
                text,
                emergencyScore
                    or info.score,
                info.mateState,
                prediction,
                true
            )
        else
            Thinking = false

            SetStatus(
                liveResolveError
                    or "LIVE MOVE RESOLVE FAILED",
                true
            )

            return false
        end
    end

    local sourcePiece =
        liveResolved.piece

    if not sourcePiece
        or sourcePiece.team ~= localTeam then

        Thinking = false

        SetStatus(
            "ORIENTATION GUARD BLOCKED",
            true
        )

        return false
    end

    -- Always execute through the game's original click pipeline.
    local sent, err =
        pcall(function()
            liveClient:clickOnTile(
                liveResolved.from[1],
                liveResolved.from[2]
            )

            task.wait(0.055)

            liveClient:clickOnTile(
                liveResolved.move[1],
                liveResolved.move[2]
            )
        end)

    if not sent then
        SetStatus(
            "CLICK PIPELINE ERROR: "
            .. tostring(err),
            true
        )

        Thinking = false
        return false
    end

    SetStatus(
        usedEmergency
            and (
                "MOVED EMERGENCY • "
                .. text
            )
            or (
                "MOVED • "
                .. text
            ),
        false
    )

    SetThinkingNarrative(
        usedEmergency
            and "Đã đi nước fallback hợp lệ. Giờ chờ phản hồi thực tế của đối thủ."
            or "Đã đi nước đã chọn. Giờ chờ phản hồi thực tế của đối thủ.",
        "decision"
    )

    Thinking = false
    return true
end

AnalyzeButton.MouseButton1Click:Connect(
    function()
        task.spawn(
            Analyze,
            false
        )
    end
)

--// ============================================================
--// MAIN LOOP
--// ============================================================

task.spawn(function()
    while ScreenGui.Parent do
        task.wait(
            Config.PollRate
        )

        local match =
            GetCurrentMatch()

        if not match then
            if LastMatchId ~= nil then
                LastMatchId = nil
                LastAutoRound = nil
                ResetShadow(nil)
                ClearVisuals()
                ResetAnalysisHUD()
                UpdatePieceHUD(nil, nil)
            end

            if not Thinking then
                SetStatus(
                    "WAITING FOR MATCH",
                    false
                )
            end

            continue
        end

        if LastMatchId ~= match.id then
            LastMatchId = match.id
            LastAutoRound = nil
            ResetShadow(match)
            ResetAnalysisHUD()

            SetStatus(
                "MATCH "
                .. tostring(match.id),
                false
            )
        end

        if not Config.AutoMove
            or Thinking then

            continue
        end

        local localTeam =
            GetLocalTeam(match)

        if localTeam == nil then
            continue
        end

        UpdatePieceHUD(
            match,
            localTeam
        )

        if match.activeTeam ~= localTeam then
            if not Thinking then
                SetStatus(
                    "OPPONENT TURN",
                    false
                )
            end

            continue
        end

        local roundKey =
            tostring(match.id)
            .. ":"
            .. tostring(match.round)
            .. ":"
            .. tostring(match.activeTeam)

        if LastAutoRound == roundKey then
            continue
        end

        LastAutoRound = roundKey

        task.spawn(
            function()
                local success =
                    Analyze(true)

                if not success then
                    -- Allow a retry if this was a temporary state.
                    task.delay(
                        0.8,
                        function()
                            if LastAutoRound
                                == roundKey then

                                LastAutoRound = nil
                            end
                        end
                    )
                end
            end
        )
    end
end)

SetExpanded(false)
SetStatus("READY", false)

print(
    "[ChessAI] Compact Sunfish v4.3 loaded (Automatic + Thinking HUD + adaptive delay)",
    "| Mode:",
    Config.Mode,
    "| Remote:",
    MovePieceRemote:GetFullName()
)
