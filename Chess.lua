--[[
    Chess AI Client v6.0.1 - EndGame Result + Bot Live Learning Fix
    Compact dropdown GUI + Original Game Sunfish + Visual Tracer

    Features
    --------
    * Uses ReplicatedStorage.Modules.SunfishHandler.Sunfish
    * Compact collapsible GUI
    * Difficulty profiles based on the game's own bot settings
    * Automatic adaptive mode: Easy/Normal/Hard/Nightmare escalation + committee
    * Vietnamese Config._Runtime.Thinking HUD generated from observable engine telemetry
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
    - Mid-match injection rebuilds Shadow by replaying currentMatch.boardStates FEN history.

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
local HttpService = game:GetService("HttpService")
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
local GameBoardModuleScript = Modules:WaitForChild("Board")

local Sunfish = require(SunfishModule)
local GameBoard = require(GameBoardModuleScript)

-- Ranked/PvP FIX:
-- The game's setupBot() normally initializes this callback, but
-- player-vs-player matches do not run setupBot at all.
--
-- Sunfish search calls the callback unconditionally for every
-- recursive node, so leaving it nil causes SEARCH ERROR in PvP/Ranked.
if type(Sunfish.setFrameKeepingFunction) == "function" then
    Sunfish.setFrameKeepingFunction(
        function(nodeCount)
            if nodeCount % 500 == 0 then
                task.wait()
            end
        end
    )
end

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

    -- v4.7 tactical safety.
    AutomaticNightmareVeto = true,
    AutomaticSafetyAudit = true,
    AutomaticSafetyProbeNodes = 42000,
    AutomaticDeepSafetyNodes = 90000,
    AutomaticSafetyCandidates = 4,
    AutomaticDefenseShortlist = 6,

    -- Competitive / anti-engine mode.
    --
    -- v4.9 could request >500k nodes in one move. On a 10-minute
    -- mobile game that can lose on clock even with a good position.
    --
    -- v5.0 uses a much smaller base budget + stage deadline.
    CompetitiveRootNodes = 22000,
    CompetitiveProbeNodes = 4500,
    CompetitiveDeepProbeNodes = 9000,
    CompetitiveRecoveryNodes = 4000,
    CompetitiveCandidateLimit = 3,
    CompetitiveFinalists = 1,
    CompetitiveMinDepth = 9,

    -- Soft wall-clock target. A search already running cannot return
    -- partial results cleanly, but new expensive stages are not started
    -- after this deadline.
    CompetitiveThinkTarget = 5.5,

    -- Clock-aware scaling.
    CompetitiveLowTimeSeconds = 120,
    CompetitiveCriticalTimeSeconds = 45,
    CompetitivePanicTimeSeconds = 20,

    -- Learning / Teacher Memory.
    LearningEnabled = true,
    LearningPersistent = true,

    -- Executor workspace storage.
    -- Delta maps this relative folder to:
    -- /storage/emulated/0/Delta/Workspace/ChessAI/
    LearningFolder = "ChessAI",
    LearningMemoryName = "LearningMemory_v1.json",
    LearningLogName = "LearningLog.txt",

    LearningMaxPositions = 5000,
    LearningSaveInterval = 8.0,
    LearningMoveBiasMax = 180,

    -- Draw/repetition learning.
    LearningRepetitionAvoidEval = 300,
    LearningRepetitionHardPenalty = 50000,
    LearningDrawWinningPenalty = 0.32,
    LearningDrawLosingReward = 0.22,
    LearningRepetitionRecentPenalty = 0.95,

    -- Native neural value learner (pure Luau).
    --
    -- Input:
    --   128 board channels + 16 engine/state features = 144
    -- Network:
    --   144 -> 96 -> 48 -> 24 -> 1
    --
    -- Hidden layers use ReLU, output uses tanh [-1, +1].
    NeuralEnabled = true,
    NeuralPersistent = true,

    NeuralWeightsName = "NeuralWeights_v1.json",
    NeuralReplayName = "NeuralReplay_v1.json",
    NeuralStatsName = "NeuralStats_v1.json",

    NeuralInputSize = 144,
    NeuralArchitecture = {144, 96, 48, 24, 1},

    NeuralReplayMax = 800,
    NeuralBatchSize = 5,
    NeuralGamma = 0.985,
    NeuralLearningRate = 0.0012,
    NeuralWeightDecay = 0.000002,
    NeuralGradientClip = 1.5,

    -- Training is deliberately off during live play.
    NeuralEndGameBatches = 14,
    NeuralIdleBatches = 1,
    NeuralIdleInterval = 5.0,
    NeuralSaveEveryUpdates = 20,

    -- Network influence starts near zero and ramps up only after it
    -- has accumulated enough real training updates.
    NeuralMinUpdates = 8,
    NeuralFullInfluenceUpdates = 500,
    NeuralMinReplayForTraining = 16,

    -- Maximum candidate contribution in centipawn-like units.
    NeuralInfluenceCp = 190,
    NeuralAutomaticCandidates = 3,

    -- Enemy reply search uses a fraction of the selected mode's nodes
    -- so Nightmare does not perform two full 65k-node searches every turn.
    PredictionNodeFactor = 0.60,

    -- Time to show the selected move before AutoMove sends it.
    AutoMovePreviewDelay = 0.55,

    -- Keep tracer visible after recommendation.
    VisualLifetime = 4.0,

    -- Active match loop interval.
    PollRate = 0.12,

    -- IMPORTANT:
    -- Never run a full getgc() hunt every PollRate while sitting in lobby.
    -- On mobile that means scanning tens of thousands of GC objects ~8x/sec.
    MatchClientHuntActiveRate = 0.65,
    MatchClientHuntIdleRate = 2.50,

    -- Hide expensive HUD render layers while there is no active board.
    SleepHUDInLobby = true,
}

local ModeOrder = {
    "Automatic",
    "Competitive",
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

    local competitive =
        DeepCopy(nightmare)

    competitive.depth =
        math.max(
            competitive.depth or 20,
            20
        )

    competitive.nodes = 120000
    competitive.worseMoveChance = 0

    competitive.lategameBonusDepth =
        math.max(
            competitive.lategameBonusDepth or 0,
            100
        )

    return {
        Baby = baby,
        Easy = easy,
        Normal = normal,
        Hard = hard,
        Nightmare = nightmare,
        Competitive = competitive,
    }
end

-- Runtime state is kept inside Config to avoid exhausting Luau's
-- top-level 200-local-register limit as this script grows.
Config._Runtime = {
    Dragging = false,
    DragStart = nil,
    MainStart = nil,

    Thinking = false,
    LastAutoRound = nil,
    LastMatchId = nil,
}

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

    local samples = {
        P = nil,
        N = nil,
        B = nil,
        R = nil,
        Q = nil,
        K = nil,
    }

    if type(match) ~= "table" then
        return counts, samples
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

                    if samples[letter] == nil
                        and typeof(piece.object) == "Instance" then

                        samples[letter] =
                            piece.object
                    end
                end
            end
        end

        return counts, samples
    end

    -- Fallback: scan currentMatch.contents.
    local source = match.contents

    if type(source) ~= "table" then
        return counts, samples
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

                        if samples[letter] == nil
                            and typeof(piece.object) == "Instance" then

                            samples[letter] =
                                piece.object
                        end
                    end
                end
            end
        end
    end

    return counts, samples
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
            Q = "",
            R = "",
            B = "",
            N = "",
            P = "",
        }
        or {
            Q = "",
            R = "",
            B = "",
            N = "",
            P = "",
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

-- Full getgc() walks are comparatively expensive on mobile.
-- v4.8 used to perform this every 0.12s in lobby when currentMatch
-- did not exist yet. Throttle the discovery pass heavily.
local LastMatchClientHunt = -math.huge
local LastKnownBoardActive = false

local function CachedClientIsUsable(client)
    if type(client) ~= "table" then
        return false
    end

    return type(
        rawget(client, "processRound")
    ) == "function"
        and type(
            rawget(client, "movePiece")
        ) == "function"
end

local function FindMatchClient(force)
    if CachedMatchClient
        and CachedClientIsUsable(
            CachedMatchClient
        ) then

        return CachedMatchClient
    end

    if type(getgc) ~= "function" then
        return nil
    end

    local now = os.clock()

    local interval =
        LastKnownBoardActive
        and Config.MatchClientHuntActiveRate
        or Config.MatchClientHuntIdleRate

    if not force
        and now - LastMatchClientHunt
            < interval then

        return nil
    end

    LastMatchClientHunt = now

    local okGC, objects =
        pcall(
            getgc,
            true
        )

    if not okGC
        or type(objects) ~= "table" then

        return nil
    end

    for _, object in ipairs(objects) do
        if type(object) == "table"
            and CachedClientIsUsable(object) then

            -- currentMatch may be nil while sitting in lobby.
            -- Do NOT require it to exist in order to cache MatchClient.
            --
            -- Narrow candidates using the other known MatchClient methods.
            if type(
                rawget(
                    object,
                    "clickOnTile"
                )
            ) == "function"
                and type(
                    rawget(
                        object,
                        "startGame"
                    )
                ) == "function"
                and type(
                    rawget(
                        object,
                        "isInMatch"
                    )
                ) == "function" then

                CachedMatchClient =
                    object

                return object
            end
        end
    end

    return nil
end

local function GetCurrentMatch()
    local client =
        FindMatchClient(false)

    if not client then
        LastKnownBoardActive = false
        return nil
    end

    local match =
        rawget(
            client,
            "currentMatch"
        )

    if type(match) ~= "table" then
        LastKnownBoardActive = false
        return nil
    end

    local active =
        match.boardExists == true
        and match.gameEnded ~= true

    LastKnownBoardActive =
        active

    if not active then
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

-- UI callbacks are assigned later after the HUD is constructed.
local SetThinkingNarrative = function() end
local SetStatus = function() end

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

    -- v4.8 replay/resync state.
    resyncToken = 0,
    historyPlies = 0,
    lastSyncMethod = nil,
}

local function MoveKey(fromPos, toPos)
    return table.concat({
        tostring(fromPos and fromPos[1]),
        tostring(fromPos and fromPos[2]),
        tostring(toPos and toPos[1]),
        tostring(toPos and toPos[2]),
    }, ":")
end



--// ============================================================
--// LEARNING MEMORY / TEACHER MEMORY
--// ============================================================

local function JoinWorkspacePath(folder, name)
    folder = tostring(folder or "")
    name = tostring(name or "")

    if folder == "" then
        return name
    end

    folder = string.gsub(folder, "[/\\]+$", "")

    return folder .. "/" .. name
end

local LearningStorage = {
    folder = Config.LearningFolder,

    memoryPath =
        JoinWorkspacePath(
            Config.LearningFolder,
            Config.LearningMemoryName
        ),

    logPath =
        JoinWorkspacePath(
            Config.LearningFolder,
            Config.LearningLogName
        ),

    folderReady = false,
}

local function EnsureLearningWorkspace()
    local folder = LearningStorage.folder

    if type(folder) ~= "string"
        or folder == "" then

        LearningStorage.folderReady = true
        return true
    end

    -- Executor file APIs are normally relative to their workspace root.
    -- On Delta this becomes:
    -- /storage/emulated/0/Delta/Workspace/ChessAI/...
    if type(isfolder) == "function" then
        local okCheck, exists =
            pcall(
                isfolder,
                folder
            )

        if okCheck and exists then
            LearningStorage.folderReady = true
            return true
        end
    end

    if type(makefolder) == "function" then
        local okCreate =
            pcall(
                makefolder,
                folder
            )

        if okCreate then
            LearningStorage.folderReady = true
            return true
        end
    end

    -- Fallback: keep using the executor workspace root if the executor
    -- exposes readfile/writefile but no folder API.
    LearningStorage.folderReady = false
    LearningStorage.memoryPath = tostring(Config.LearningMemoryName)
    LearningStorage.logPath = tostring(Config.LearningLogName)

    return false
end

EnsureLearningWorkspace()

LearningStorage.neuralWeightsPath =
    LearningStorage.folderReady
    and JoinWorkspacePath(
        Config.LearningFolder,
        Config.NeuralWeightsName
    )
    or tostring(
        Config.NeuralWeightsName
    )

LearningStorage.neuralReplayPath =
    LearningStorage.folderReady
    and JoinWorkspacePath(
        Config.LearningFolder,
        Config.NeuralReplayName
    )
    or tostring(
        Config.NeuralReplayName
    )

LearningStorage.neuralStatsPath =
    LearningStorage.folderReady
    and JoinWorkspacePath(
        Config.LearningFolder,
        Config.NeuralStatsName
    )
    or tostring(
        Config.NeuralStatsName
    )

local Learning = {
    version = 2,
    loaded = false,
    persistent = false,
    dirty = false,
    lastSave = 0,

    data = {
        version = 2,

        games = {
            played = 0,
            wins = 0,
            losses = 0,
            draws = 0,
            unknown = 0,
        },

        -- Exact Sunfish position -> our move history.
        positions = {},

        -- Exact opponent-to-move position -> real replies observed.
        teacher = {},
    },

    session = nil,
    logBuffer = {},
}

local function LearningMoveId(move)
    if type(move) ~= "table" then
        return "?"
    end

    return table.concat({
        tostring(move[1] or "?"),
        tostring(move[2] or "?"),
        tostring(move[3] or ""),
        tostring(move[4] or ""),
    }, ":")
end

local function LearningMoveCopy(move)
    if type(move) ~= "table" then
        return nil
    end

    return {
        move[1],
        move[2],
        move[3],
        move[4],
    }
end

local function LearningFlags(flags)
    if type(flags) ~= "table" then
        return "--"
    end

    return (
        tostring(
            flags[1] == true
            and 1
            or 0
        )
        .. tostring(
            flags[2] == true
            and 1
            or 0
        )
    )
end

local function LearningPositionKey(position)
    if type(position) ~= "table"
        or type(position.board) ~= "string" then

        return nil
    end

    local board =
        string.gsub(
            position.board,
            "%s",
            ""
        )

    return table.concat({
        board,
        position.player and "W" or "B",
        LearningFlags(position.wc),
        LearningFlags(position.bc),
        tostring(position.ep or 0),
        tostring(position.kp or 0),
    }, "|")
end

local function LearningTimestamp()
    local ok, stamp =
        pcall(
            os.date,
            "!%Y-%m-%dT%H:%M:%SZ"
        )

    return ok
        and tostring(stamp)
        or tostring(os.time())
end

local function LearningLog(text)
    local line =
        string.format(
            "[%s] %s",
            LearningTimestamp(),
            tostring(text)
        )

    print(
        "[ChessAI Learn]",
        line
    )

    Learning.logBuffer[
        #Learning.logBuffer + 1
    ] = line

    if type(appendfile) == "function" then
        local payload =
            line .. "\n"

        task.spawn(
            function()
                pcall(
                    appendfile,
                    LearningStorage.logPath,
                    payload
                )
            end
        )

        Learning.logBuffer = {}
    end
end

local function LearningEnsureData(data)
    if type(data) ~= "table" then
        return false
    end

    data.version =
        math.max(
            tonumber(data.version)
                or 1,
            2
        )

    data.games =
        type(data.games) == "table"
        and data.games
        or {}

    for _, field in ipairs({
        "played",
        "wins",
        "losses",
        "draws",
        "unknown",
    }) do
        data.games[field] =
            tonumber(
                data.games[field]
            )
            or 0
    end

    data.positions =
        type(data.positions) == "table"
        and data.positions
        or {}

    data.teacher =
        type(data.teacher) == "table"
        and data.teacher
        or {}

    return true
end

local function LearningLoad()
    if not Config.LearningEnabled
        or Learning.loaded then

        return
    end

    Learning.loaded = true

    Learning.persistent =
        Config.LearningPersistent
        and type(readfile) == "function"
        and type(writefile) == "function"

    LearningLog(
        string.format(
            "Storage: %s%s",
            tostring(
                LearningStorage.memoryPath
            ),
            LearningStorage.folderReady
                and " (workspace folder ready)"
                or " (workspace-root fallback)"
        )
    )

    if not Learning.persistent then
        LearningLog(
            "Memory = RAM only (executor has no readfile/writefile)."
        )

        return
    end

    local okRead, raw =
        pcall(
            readfile,
            LearningStorage.memoryPath
        )

    if not okRead
        or type(raw) ~= "string"
        or #raw == 0 then

        LearningLog(
            "No previous memory file; starting fresh."
        )

        return
    end

    local okDecode, decoded =
        pcall(
            HttpService.JSONDecode,
            HttpService,
            raw
        )

    if okDecode
        and LearningEnsureData(
            decoded
        ) then

        Learning.data = decoded

        LearningLog(
            string.format(
                "Loaded memory: %d games • W/D/L %d/%d/%d.",
                Learning.data.games.played
                    or 0,
                Learning.data.games.wins
                    or 0,
                Learning.data.games.draws
                    or 0,
                Learning.data.games.losses
                    or 0
            )
        )
    else
        LearningLog(
            "Memory JSON decode failed; using fresh RAM memory."
        )
    end
end

local function LearningTrimMap(map)
    if type(map) ~= "table" then
        return
    end

    local count = 0

    for _ in pairs(map) do
        count += 1
    end

    if count
        <= Config.LearningMaxPositions then

        return
    end

    local entries = {}

    for key, value in pairs(map) do
        entries[#entries + 1] = {
            key = key,
            seen =
                type(value) == "table"
                and tonumber(value.seen)
                or 0,
        }
    end

    table.sort(
        entries,
        function(a, b)
            return a.seen < b.seen
        end
    )

    local removeCount =
        count
        - Config.LearningMaxPositions

    for i = 1, removeCount do
        map[
            entries[i].key
        ] = nil
    end
end

local function LearningSave(force)
    if not Config.LearningEnabled then
        return
    end

    if not Learning.dirty
        and not force then

        return
    end

    local now =
        os.clock()

    if not force
        and now - Learning.lastSave
            < Config.LearningSaveInterval then

        return
    end

    Learning.lastSave = now

    LearningTrimMap(
        Learning.data.positions
    )

    LearningTrimMap(
        Learning.data.teacher
    )

    if Learning.persistent
        and type(writefile)
            == "function" then

        local okEncode, raw =
            pcall(
                HttpService.JSONEncode,
                HttpService,
                Learning.data
            )

        if okEncode
            and type(raw) == "string" then

            local okWrite =
                pcall(
                    writefile,
                    LearningStorage.memoryPath,
                    raw
                )

            if okWrite then
                Learning.dirty = false
            end
        end

        -- Fallback log persistence if appendfile is unavailable.
        if #Learning.logBuffer > 0
            and type(appendfile)
                ~= "function" then

            local previous = ""

            local okOld, old =
                pcall(
                    readfile,
                    LearningStorage.logPath
                )

            if okOld
                and type(old) == "string" then

                previous = old
            end

            local combined =
                previous
                .. table.concat(
                    Learning.logBuffer,
                    "\n"
                )
                .. "\n"

            if #combined > 250000 then
                combined =
                    string.sub(
                        combined,
                        #combined - 250000
                    )
            end

            pcall(
                writefile,
                LearningStorage.logPath,
                combined
            )

            Learning.logBuffer = {}
        end
    end
end

local function LearningPositionBucket(
    positionKey,
    create
)
    if not positionKey then
        return nil
    end

    local bucket =
        Learning.data.positions[
            positionKey
        ]

    if not bucket and create then
        bucket = {
            seen = 0,
            moves = {},
        }

        Learning.data.positions[
            positionKey
        ] = bucket
    end

    return bucket
end

local function LearningTeacherBucket(
    positionKey,
    create
)
    if not positionKey then
        return nil
    end

    local bucket =
        Learning.data.teacher[
            positionKey
        ]

    if not bucket and create then
        bucket = {
            seen = 0,
            replies = {},
        }

        Learning.data.teacher[
            positionKey
        ] = bucket
    end

    return bucket
end

local function LearningGetOwnMoveEntry(
    positionKey,
    move,
    create
)
    local bucket =
        LearningPositionBucket(
            positionKey,
            create
        )

    if not bucket then
        return nil
    end

    bucket.moves =
        type(bucket.moves) == "table"
        and bucket.moves
        or {}

    local moveId =
        LearningMoveId(move)

    local entry =
        bucket.moves[
            moveId
        ]

    if not entry and create then
        entry = {
            move =
                LearningMoveCopy(move),
            seen = 0,
            wins = 0,
            losses = 0,
            draws = 0,
            experience = 0,
            lastEval = 0,
        }

        bucket.moves[
            moveId
        ] = entry
    end

    return entry,
        bucket
end

local function LearningGetTeacherEntry(
    positionKey,
    move,
    create
)
    local bucket =
        LearningTeacherBucket(
            positionKey,
            create
        )

    if not bucket then
        return nil
    end

    bucket.replies =
        type(bucket.replies) == "table"
        and bucket.replies
        or {}

    local moveId =
        LearningMoveId(move)

    local entry =
        bucket.replies[
            moveId
        ]

    if not entry and create then
        entry = {
            move =
                LearningMoveCopy(move),
            seen = 0,
            wins = 0,
            losses = 0,
            draws = 0,
            punish = 0,
        }

        bucket.replies[
            moveId
        ] = entry
    end

    return entry,
        bucket
end

local function LearningOwnMoveBias(
    position,
    move
)
    if not Config.LearningEnabled then
        return 0
    end

    local key =
        LearningPositionKey(
            position
        )

    local entry =
        key
        and LearningGetOwnMoveEntry(
            key,
            move,
            false
        )

    if not entry then
        return 0
    end

    local games =
        (tonumber(entry.wins) or 0)
        + (tonumber(entry.losses) or 0)
        + (tonumber(entry.draws) or 0)

    if games <= 0 then
        return 0
    end

    -- Damped so one lucky result cannot dominate the engine.
    local history =
        (
            (tonumber(entry.wins) or 0)
            - (tonumber(entry.losses) or 0)
            + 0.15
                * (tonumber(entry.draws) or 0)
        )
        / (games + 2.5)

    local experience =
        tonumber(entry.experience)
        or 0

    return math.clamp(
        history
            * Config.LearningMoveBiasMax
        + experience * 18,
        -Config.LearningMoveBiasMax,
        Config.LearningMoveBiasMax
    )
end

local function LearningFindLegalStoredMove(
    position,
    storedMove
)
    if type(position) ~= "table"
        or type(storedMove) ~= "table" then

        return nil
    end

    local targetId =
        LearningMoveId(
            storedMove
        )

    local okMoves, moves =
        pcall(function()
            return position:genMoves()
        end)

    if not okMoves
        or type(moves) ~= "table" then

        return nil
    end

    for _, move in pairs(moves) do
        if LearningMoveId(move)
            == targetId then

            return move
        end
    end

    return nil
end

local function LearningBestTeacherReply(
    position
)
    if not Config.LearningEnabled then
        return nil
    end

    local key =
        LearningPositionKey(
            position
        )

    local bucket =
        key
        and LearningTeacherBucket(
            key,
            false
        )

    if not bucket
        or type(bucket.replies)
            ~= "table" then

        return nil
    end

    local best
    local bestWeight =
        -math.huge

    for _, entry in pairs(
        bucket.replies
    ) do
        if type(entry) == "table"
            and type(entry.move)
                == "table" then

            local legal =
                LearningFindLegalStoredMove(
                    position,
                    entry.move
                )

            if legal then
                local weight =
                    (tonumber(entry.punish) or 0)
                        * 100
                    + (tonumber(entry.losses) or 0)
                        * 18
                    + math.min(
                        tonumber(entry.seen) or 0,
                        8
                    )
                        * 2

                if weight > bestWeight then
                    bestWeight = weight

                    best = {
                        move = legal,
                        entry = entry,
                        weight = weight,
                        positionKey = key,
                    }
                end
            end
        end
    end

    return best
end

local function LearningStartSession(
    match
)
    if not Config.LearningEnabled
        or type(match) ~= "table" then

        return
    end

    LearningLoad()

    Learning.session = {
        matchId = match.id,
        matchRef = match,
        localTeam =
            GetLocalTeam(match),
        startedAt =
            os.clock(),

        decisions = {},
        teacherEvents = {},
        seenTeacherEvents = {},

        positionVisits = {},
        sunfishVisits = {},

        historyIndex = 0,
        historyPosition = nil,
        historyFirstFEN = nil,

        repetitionCounts = {},
        repetitionDraw = false,
        repetitionKey = nil,

        -- v6 neural trajectory: only positions where it is our turn are
        -- used for full-ply TD transitions.
        neuralPendingState = nil,
        neuralTrajectory = {},

        -- Built-in Sunfish bot fallback. Board history can skip a half-move
        -- on some bot matches, so keep a live before/after snapshot too.
        botTeacherPendingFEN = nil,
        botTeacherPendingPosition = nil,
        botLastNeuralKey = nil,

        resultHint = nil,
        resultReason = nil,
        endRemoteSeen = false,

        finalized = false,
        endDetectedAt = nil,
    }

    LearningLog(
        string.format(
            "MATCH_START id=%s mode=%s team=%s",
            tostring(match.id),
            tostring(match.mode),
            tostring(
                Learning.session.localTeam
            )
        )
    )
end

local function LearningEnsureSession(
    match
)
    if not Config.LearningEnabled
        or type(match) ~= "table" then

        return nil
    end

    if not Learning.session
        or Learning.session.matchId
            ~= match.id then

        LearningStartSession(
            match
        )
    end

    return Learning.session
end

local function LearningRecordOwnMove(
    match,
    position,
    move,
    info,
    source
)
    if not Config.LearningEnabled
        or type(position) ~= "table"
        or type(move) ~= "table" then

        return
    end

    local session =
        LearningEnsureSession(
            match
        )

    if not session then
        return
    end

    local positionKey =
        LearningPositionKey(
            position
        )

    local entry,
        bucket =
        LearningGetOwnMoveEntry(
            positionKey,
            move,
            true
        )

    if not entry then
        return
    end

    entry.seen =
        (tonumber(entry.seen) or 0)
        + 1

    entry.lastEval =
        tonumber(
            info
            and info.score
        )
        or tonumber(entry.lastEval)
        or 0

    bucket.seen =
        (tonumber(bucket.seen) or 0)
        + 1

    session.positionVisits[
        positionKey
    ] =
        (
            tonumber(
                session.positionVisits[
                    positionKey
                ]
            )
            or 0
        )
        + 1

    local positionVisit =
        session.positionVisits[
            positionKey
        ]

    session.decisions[
        #session.decisions + 1
    ] = {
        positionKey =
            positionKey,
        moveId =
            LearningMoveId(move),
        move =
            LearningMoveCopy(move),
        source =
            source or "AI",
        eval =
            tonumber(
                info
                and info.score
            )
            or 0,

        positionVisit =
            positionVisit,
    }

    Learning.dirty = true

    local thinkTime =
        info
        and info.competitive
        and info.competitive.elapsed

    LearningLog(
        string.format(
            "OUR_MOVE id=%s source=%s mode=%s move=%s eval=%+.2f%s",
            tostring(match.id),
            tostring(source or "AI"),
            tostring(Config.Mode),
            LearningMoveId(move),
            (
                tonumber(
                    info
                    and info.score
                )
                or 0
            ) / 100,
            thinkTime
                and string.format(
                    " think=%.2fs",
                    thinkTime
                )
                or ""
        )
    )

    LearningSave(false)
end

local function LearningRecordTeacherMove(
    match,
    position,
    move
)
    if not Config.LearningEnabled
        or type(position) ~= "table"
        or type(move) ~= "table" then

        return
    end

    local session =
        LearningEnsureSession(
            match
        )

    if not session then
        return
    end

    local positionKey =
        LearningPositionKey(
            position
        )

    local eventKey =
        tostring(positionKey)
        .. ">"
        .. LearningMoveId(move)

    if session.seenTeacherEvents[
        eventKey
    ] then
        return
    end

    session.seenTeacherEvents[
        eventKey
    ] = true

    local entry,
        bucket =
        LearningGetTeacherEntry(
            positionKey,
            move,
            true
        )

    if not entry then
        return
    end

    entry.seen =
        (tonumber(entry.seen) or 0)
        + 1

    bucket.seen =
        (tonumber(bucket.seen) or 0)
        + 1

    session.teacherEvents[
        #session.teacherEvents + 1
    ] = {
        positionKey =
            positionKey,
        moveId =
            LearningMoveId(move),
        move =
            LearningMoveCopy(move),
    }

    Learning.dirty = true

    LearningLog(
        string.format(
            "TEACHER_REPLY id=%s move=%s seen=%d",
            tostring(match.id),
            LearningMoveId(move),
            tonumber(entry.seen) or 0
        )
    )

    LearningSave(false)
end

local function LearningResolveResult(
    match,
    localTeam
)
    if type(match) ~= "table" then
        return "unknown"
    end

    local winner =
        match.winner

    local victoryType =
        match.victoryType

    if type(victoryType) == "string" then
        local lowerVictory =
            string.lower(
                victoryType
            )

        if string.find(lowerVictory, "repetition", 1, true)
            or string.find(lowerVictory, "fifty", 1, true)
            or string.find(lowerVictory, "stalemate", 1, true)
            or string.find(lowerVictory, "draw", 1, true)
            or string.find(lowerVictory, "remis", 1, true) then

            return "draw"
        end
    end

    if winner == nil
        or winner == "-"
        or winner == "" then

        return "unknown"
    end

    if type(winner) == "boolean"
        and type(localTeam)
            == "boolean" then

        return winner == localTeam
            and "win"
            or "loss"
    end

    if typeof(winner) == "Instance"
        and winner:IsA("Player") then

        return winner == LocalPlayer
            and "win"
            or "loss"
    end

    if type(winner) == "number"
        and winner
            == LocalPlayer.UserId then

        return "win"
    end

    if type(winner) == "string" then
        local lower =
            string.lower(winner)

        -- PGN-style result values used by the game's Board module.
        if winner == "½-½"
            or lower == "1/2-1/2" then

            return "draw"
        end

        if winner == "1-0"
            and type(localTeam)
                == "boolean" then

            return localTeam
                and "win"
                or "loss"
        end

        if winner == "0-1"
            and type(localTeam)
                == "boolean" then

            return not localTeam
                and "win"
                or "loss"
        end

        if string.find(
                lower,
                "draw",
                1,
                true
            )
            or string.find(
                lower,
                "remis",
                1,
                true
            )
            or string.find(
                lower,
                "stalemate",
                1,
                true
            )
            or string.find(
                lower,
                "repetition",
                1,
                true
            ) then

            return "draw"
        end

        if lower == "white"
            and type(localTeam)
                == "boolean" then

            return localTeam
                and "win"
                or "loss"
        end

        if lower == "black"
            and type(localTeam)
                == "boolean" then

            return not localTeam
                and "win"
                or "loss"
        end

        if lower
            == string.lower(
                LocalPlayer.Name
            )
            or lower
                == tostring(
                    LocalPlayer.UserId
                ) then

            return "win"
        end
    end

    return "unknown"
end

local function LearningFinalizeSession(
    result,
    reason
)
    local session =
        Learning.session

    if not session
        or session.finalized then

        return
    end

    session.finalized = true

    result =
        result
        or "unknown"

    reason =
        tostring(
            reason
            or session.resultReason
            or "?"
        )

    local games =
        Learning.data.games

    games.played =
        (tonumber(games.played) or 0)
        + 1

    if result == "win" then
        games.wins =
            (tonumber(games.wins) or 0)
            + 1

    elseif result == "loss" then
        games.losses =
            (tonumber(games.losses) or 0)
            + 1

    elseif result == "draw" then
        games.draws =
            (tonumber(games.draws) or 0)
            + 1

    else
        games.unknown =
            (tonumber(games.unknown) or 0)
            + 1
    end

    local isRepetition =
        result == "draw"
        and (
            session.repetitionDraw
            or string.find(
                string.lower(reason),
                "repetition",
                1,
                true
            ) ~= nil
        )

    local decisionCount =
        #session.decisions

    -- W/D/L counters are once-per-game per (position,move), while
    -- experience remains occurrence-sensitive.
    local creditedOwn = {}

    for index, decision in ipairs(
        session.decisions
    ) do
        local entry =
            LearningGetOwnMoveEntry(
                decision.positionKey,
                decision.move,
                false
            )

        if entry then
            local distance =
                decisionCount - index

            local credit =
                0.28
                + 0.72
                    * math.exp(
                        -distance / 6
                    )

            local statKey =
                tostring(decision.positionKey)
                .. ">"
                .. tostring(decision.moveId)

            if not creditedOwn[statKey] then
                creditedOwn[statKey] = true

                if result == "win" then
                    entry.wins =
                        (tonumber(entry.wins) or 0)
                        + 1

                elseif result == "loss" then
                    entry.losses =
                        (tonumber(entry.losses) or 0)
                        + 1

                elseif result == "draw" then
                    entry.draws =
                        (tonumber(entry.draws) or 0)
                        + 1
                end
            end

            local delta = 0

            if result == "win" then
                delta = credit

            elseif result == "loss" then
                delta = -credit

            elseif result == "draw" then
                local eval =
                    tonumber(decision.eval)
                    or 0

                -- A draw from a losing position is useful.
                -- A draw from a clearly winning position is a failure.
                if eval <= -Config.LearningRepetitionAvoidEval then
                    delta =
                        Config.LearningDrawLosingReward
                        * credit

                elseif eval >= Config.LearningRepetitionAvoidEval then
                    delta =
                        -Config.LearningDrawWinningPenalty
                        * credit
                else
                    delta =
                        0.02 * credit
                end

                if isRepetition then
                    local recent =
                        distance <= 6

                    local repeatedDecision =
                        (
                            tonumber(
                                decision.positionVisit
                            )
                            or 0
                        ) >= 2

                    if recent
                        or repeatedDecision then

                        delta -=
                            Config.LearningRepetitionRecentPenalty
                            * credit

                        entry.repetitionDraws =
                            (
                                tonumber(entry.repetitionDraws)
                                or 0
                            )
                            + 1
                    end
                end
            end

            entry.experience =
                (tonumber(entry.experience) or 0)
                + delta
        end
    end

    local teacherCount =
        #session.teacherEvents

    local creditedTeacher = {}

    for index, event in ipairs(
        session.teacherEvents
    ) do
        local entry =
            LearningGetTeacherEntry(
                event.positionKey,
                event.move,
                false
            )

        if entry then
            local distance =
                teacherCount - index

            local credit =
                0.30
                + 0.70
                    * math.exp(
                        -distance / 5
                    )

            local statKey =
                tostring(event.positionKey)
                .. ">"
                .. tostring(event.moveId)

            if not creditedTeacher[statKey] then
                creditedTeacher[statKey] = true

                if result == "loss" then
                    entry.losses =
                        (tonumber(entry.losses) or 0)
                        + 1

                elseif result == "win" then
                    entry.wins =
                        (tonumber(entry.wins) or 0)
                        + 1

                elseif result == "draw" then
                    entry.draws =
                        (tonumber(entry.draws) or 0)
                        + 1
                end
            end

            if result == "loss" then
                entry.punish =
                    (tonumber(entry.punish) or 0)
                    + credit

            elseif result == "win" then
                entry.punish =
                    math.max(
                        0,
                        (tonumber(entry.punish) or 0)
                        - 0.12 * credit
                    )

            elseif result == "draw" then
                entry.punish =
                    (tonumber(entry.punish) or 0)
                    + (
                        isRepetition
                        and 0.04
                        or 0.08
                    )
                        * credit
            end
        end
    end

    Learning.dirty = true

    LearningLog(
        string.format(
            "MATCH_RESULT id=%s result=%s reason=%s decisions=%d teacher=%d | W/D/L=%d/%d/%d%s",
            tostring(session.matchId),
            tostring(result),
            tostring(reason),
            decisionCount,
            teacherCount,
            games.wins or 0,
            games.draws or 0,
            games.losses or 0,
            isRepetition
                and " • REPETITION_LEARNED"
                or ""
        )
    )

    if type(
        Learning.Neural
    ) == "table"
        and type(
            Learning.Neural.FinalizeGame
        ) == "function" then

        Learning.Neural.FinalizeGame(
            session,
            result,
            reason
        )
    end

    LearningSave(true)
    Learning.session = nil
end

local function LearningPollResult()
    local session =
        Learning.session

    if not session
        or session.finalized then

        return
    end

    local match =
        session.matchRef

    if type(
        Learning.ProcessHistory
    ) == "function"
        and type(match) == "table" then

        pcall(
            Learning.ProcessHistory,
            match
        )
    end

    local ended =
        type(match) == "table"
        and match.gameEnded == true

    if not ended
        and not session.endRemoteSeen then

        return
    end

    local result =
        LearningResolveResult(
            match,
            session.localTeam
        )

    local reason =
        session.resultReason
        or "gameEnded"

    if result == "unknown"
        and session.resultHint then

        result =
            session.resultHint
    end

    if result == "unknown"
        and session.repetitionDraw then

        result = "draw"
        reason = "repetition"
    end

    if result == "unknown"
        and type(match) == "table"
        and (
            tonumber(
                match.fiftyMoveCounter
            )
            or 0
        ) >= 100 then

        result = "draw"
        reason = "fiftymoves"
    end

    if result == "unknown" then
        session.endDetectedAt =
            session.endDetectedAt
            or os.clock()

        if os.clock()
            - session.endDetectedAt
            < 1.50 then

            return
        end
    end

    LearningFinalizeSession(
        result,
        reason
    )
end


--// ============================================================
--// v6 NATIVE NEURAL VALUE NETWORK
--//
--// Pure Luau implementation:
--//   144 -> 96 -> 48 -> 24 -> 1
--//   ReLU hidden layers
--//   tanh value output
--//   SGD + gradient clipping + tiny L2 decay
--//   prioritized replay
--//   TD learning + Monte-Carlo terminal targets
--//
--// The model predicts position value from OUR side's perspective.
--// Sunfish remains the chess search backbone; neural output is a
--// gradually-ramped candidate reranking signal.
--// ============================================================

Learning.Neural = {
    version = 1,
    loaded = false,
    persistent = false,
    training = false,
    jobRunning = false,

    model = nil,

    replay = {
        version = 1,
        samples = {},
        added = 0,
    },

    stats = {
        version = 1,
        games = 0,
        wins = 0,
        draws = 0,
        losses = 0,
        unknown = 0,

        updates = 0,
        samplesSeen = 0,
        lastLoss = 0,
        avgLoss = 0,
        lastTrainSeconds = 0,
    },

    dirtyWeights = false,
    dirtyReplay = false,
    dirtyStats = false,

    lastSaveUpdate = 0,
    lastIdleTrain = 0,
}

Learning.Neural.Tanh = function(x)
    x =
        math.clamp(
            tonumber(x) or 0,
            -20,
            20
        )

    local e =
        math.exp(
            2 * x
        )

    return (e - 1)
        / (e + 1)
end

Learning.Neural.RandomWeight = function(inputSize)
    local limit =
        math.sqrt(
            6
            / math.max(
                tonumber(inputSize) or 1,
                1
            )
        )

    return (
        math.random() * 2 - 1
    ) * limit
end

Learning.Neural.NewLayer = function(inputSize, outputSize)
    local layer = {
        inputSize = inputSize,
        outputSize = outputSize,
        weights = {},
        bias = {},
    }

    local total =
        inputSize
        * outputSize

    for index = 1, total do
        layer.weights[index] =
            Learning.Neural.RandomWeight(
                inputSize
            )
    end

    for index = 1, outputSize do
        layer.bias[index] = 0
    end

    return layer
end

Learning.Neural.NewModel = function()
    local architecture =
        Config.NeuralArchitecture

    local model = {
        version = 1,
        architecture = {},
        layers = {},
    }

    for index, size in ipairs(
        architecture
    ) do
        model.architecture[index] =
            tonumber(size)
    end

    for index = 1,
        #architecture - 1 do

        model.layers[index] =
            Learning.Neural.NewLayer(
                architecture[index],
                architecture[index + 1]
            )
    end

    return model
end

Learning.Neural.ValidateModel = function(model)
    if type(model) ~= "table"
        or type(model.architecture) ~= "table"
        or type(model.layers) ~= "table" then

        return false
    end

    if #model.architecture
        ~= #Config.NeuralArchitecture then

        return false
    end

    for index, expected in ipairs(
        Config.NeuralArchitecture
    ) do
        if tonumber(
            model.architecture[index]
        ) ~= expected then

            return false
        end
    end

    if #model.layers
        ~= #Config.NeuralArchitecture - 1 then

        return false
    end

    for index, layer in ipairs(
        model.layers
    ) do
        local inputSize =
            Config.NeuralArchitecture[index]

        local outputSize =
            Config.NeuralArchitecture[index + 1]

        if type(layer) ~= "table"
            or tonumber(layer.inputSize)
                ~= inputSize
            or tonumber(layer.outputSize)
                ~= outputSize
            or type(layer.weights)
                ~= "table"
            or type(layer.bias)
                ~= "table"
            or #layer.weights
                ~= inputSize * outputSize
            or #layer.bias
                ~= outputSize then

            return false
        end
    end

    return true
end

Learning.Neural.SafeDecodeFile = function(path)
    if type(readfile) ~= "function" then
        return nil
    end

    local okRead, raw =
        pcall(
            readfile,
            path
        )

    if not okRead
        or type(raw) ~= "string"
        or #raw == 0 then

        return nil
    end

    local okDecode, data =
        pcall(
            HttpService.JSONDecode,
            HttpService,
            raw
        )

    if not okDecode then
        return nil
    end

    return data
end

Learning.Neural.SafeEncodeFile = function(path, data)
    if type(writefile) ~= "function" then
        return false
    end

    local okEncode, raw =
        pcall(
            HttpService.JSONEncode,
            HttpService,
            data
        )

    if not okEncode
        or type(raw) ~= "string" then

        return false
    end

    return pcall(
        writefile,
        path,
        raw
    )
end

Learning.Neural.Load = function()
    if Learning.Neural.loaded
        or not Config.NeuralEnabled then

        return
    end

    Learning.Neural.loaded = true

    Learning.Neural.persistent =
        Config.NeuralPersistent
        and type(readfile) == "function"
        and type(writefile) == "function"

    local weights =
        Learning.Neural.SafeDecodeFile(
            LearningStorage.neuralWeightsPath
        )

    if Learning.Neural.ValidateModel(
        weights
    ) then
        Learning.Neural.model = weights
    else
        Learning.Neural.model =
            Learning.Neural.NewModel()

        Learning.Neural.dirtyWeights = true
    end

    local replay =
        Learning.Neural.SafeDecodeFile(
            LearningStorage.neuralReplayPath
        )

    if type(replay) == "table"
        and type(replay.samples) == "table" then

        Learning.Neural.replay = replay

        Learning.Neural.replay.version =
            tonumber(
                Learning.Neural.replay.version
            )
            or 1

        Learning.Neural.replay.added =
            tonumber(
                Learning.Neural.replay.added
            )
            or #Learning.Neural.replay.samples
    end

    local stats =
        Learning.Neural.SafeDecodeFile(
            LearningStorage.neuralStatsPath
        )

    if type(stats) == "table" then
        for key, defaultValue in pairs(
            Learning.Neural.stats
        ) do
            if stats[key] ~= nil then
                Learning.Neural.stats[key] =
                    stats[key]
            else
                Learning.Neural.stats[key] =
                    defaultValue
            end
        end
    end

    -- Trim a replay file if config was reduced between versions.
    while #Learning.Neural.replay.samples
        > Config.NeuralReplayMax do

        table.remove(
            Learning.Neural.replay.samples,
            1
        )
    end

    LearningLog(
        string.format(
            "NEURAL_LOAD arch=144>96>48>24>1 replay=%d updates=%d loss=%.5f mode=%s",
            #Learning.Neural.replay.samples,
            tonumber(
                Learning.Neural.stats.updates
            ) or 0,
            tonumber(
                Learning.Neural.stats.avgLoss
            ) or 0,
            Learning.Neural.persistent
                and "persistent"
                or "RAM"
        )
    )
end

Learning.Neural.Save = function(force)
    if not Config.NeuralEnabled
        or not Learning.Neural.loaded then

        return
    end

    if not Learning.Neural.persistent then
        return
    end

    local updates =
        tonumber(
            Learning.Neural.stats.updates
        )
        or 0

    if not force
        and updates
            - Learning.Neural.lastSaveUpdate
            < Config.NeuralSaveEveryUpdates then

        return
    end

    Learning.Neural.lastSaveUpdate =
        updates

    if Learning.Neural.dirtyWeights
        or force then

        if Learning.Neural.SafeEncodeFile(
            LearningStorage.neuralWeightsPath,
            Learning.Neural.model
        ) then
            Learning.Neural.dirtyWeights = false
        end
    end

    if Learning.Neural.dirtyReplay
        or force then

        if Learning.Neural.SafeEncodeFile(
            LearningStorage.neuralReplayPath,
            Learning.Neural.replay
        ) then
            Learning.Neural.dirtyReplay = false
        end
    end

    if Learning.Neural.dirtyStats
        or force then

        if Learning.Neural.SafeEncodeFile(
            LearningStorage.neuralStatsPath,
            Learning.Neural.stats
        ) then
            Learning.Neural.dirtyStats = false
        end
    end
end

Learning.Neural.SwapCase = function(char)
    if string.match(
        char,
        "%u"
    ) then
        return string.lower(char)
    end

    if string.match(
        char,
        "%l"
    ) then
        return string.upper(char)
    end

    return char
end

Learning.Neural.PieceTypeValue = function(char)
    local upper =
        string.upper(
            tostring(char or "")
        )

    if upper == "P" then
        return 0.17, 1
    elseif upper == "N" then
        return 0.33, 3
    elseif upper == "B" then
        return 0.42, 3.2
    elseif upper == "R" then
        return 0.58, 5
    elseif upper == "Q" then
        return 0.83, 9
    elseif upper == "K" then
        return 1.00, 0
    end

    return 0, 0
end

Learning.Neural.ExtractFeatures = function(
    position,
    localTeam
)
    if not Config.NeuralEnabled
        or type(position) ~= "table"
        or type(position.board) ~= "string"
        or type(localTeam) ~= "boolean" then

        return nil
    end

    local squares = {}

    for index = 1,
        #position.board do

        local char =
            string.sub(
                position.board,
                index,
                index
            )

        if char == "."
            or string.match(
                char,
                "[prnbqkPRNBQK]"
            ) then

            squares[
                #squares + 1
            ] = char
        end
    end

    if #squares ~= 64 then
        return nil
    end

    local canonical = {}

    if position.player
        == localTeam then

        for index = 1, 64 do
            canonical[index] =
                squares[index]
        end
    else
        -- Sunfish rotates/swapcases the board every ply. Undo that so
        -- the network always sees the board from OUR stable perspective.
        for index = 1, 64 do
            canonical[index] =
                Learning.Neural.SwapCase(
                    squares[
                        65 - index
                    ]
                )
        end
    end

    local features = {}

    local ownMaterial = 0
    local enemyMaterial = 0
    local ownCount = 0
    local enemyCount = 0

    for squareIndex = 1, 64 do
        local char =
            canonical[squareIndex]

        local featureIndex =
            (squareIndex - 1)
            * 2
            + 1

        if char == "." then
            features[featureIndex] = 0
            features[
                featureIndex + 1
            ] = 0
        else
            local isOwn =
                string.match(
                    char,
                    "%u"
                ) ~= nil

            local typeValue,
                material =
                Learning.Neural.PieceTypeValue(
                    char
                )

            features[featureIndex] =
                isOwn
                and 1
                or -1

            features[
                featureIndex + 1
            ] =
                typeValue

            if isOwn then
                ownMaterial += material
                ownCount += 1
            else
                enemyMaterial += material
                enemyCount += 1
            end
        end
    end

    local localToMove =
        position.player
        == localTeam

    local positionScore =
        tonumber(
            position.score
        )
        or 0

    if not localToMove then
        positionScore =
            -positionScore
    end

    local ownCastling
    local enemyCastling

    if localToMove then
        ownCastling =
            position.wc

        enemyCastling =
            position.bc
    else
        ownCastling =
            position.bc

        enemyCastling =
            position.wc
    end

    local repetitionVisit = 0

    if Learning.session
        and type(
            Learning.session.sunfishVisits
        ) == "table" then

        local key =
            LearningPositionKey(
                position
            )

        repetitionVisit =
            key
            and (
                tonumber(
                    Learning.session.sunfishVisits[
                        key
                    ]
                )
                or 0
            )
            or 0
    end

    local extra = {
        localToMove and 1 or -1,

        Learning.Neural.Tanh(
            positionScore / 600
        ),

        math.clamp(
            (
                tonumber(
                    position.gamePhase
                )
                or 0
            ) / 32,
            0,
            1
        ),

        math.clamp(
            repetitionVisit / 3,
            0,
            1
        ),

        type(ownCastling) == "table"
            and ownCastling[1] == true
            and 1
            or 0,

        type(ownCastling) == "table"
            and ownCastling[2] == true
            and 1
            or 0,

        type(enemyCastling) == "table"
            and enemyCastling[1] == true
            and 1
            or 0,

        type(enemyCastling) == "table"
            and enemyCastling[2] == true
            and 1
            or 0,

        (
            tonumber(position.ep)
            and tonumber(position.ep) ~= 0
            and tonumber(position.ep) ~= 119
        )
            and 1
            or 0,

        (
            tonumber(position.kp)
            and tonumber(position.kp) ~= 0
            and tonumber(position.kp) ~= 119
        )
            and 1
            or 0,

        math.clamp(
            ownMaterial / 39,
            0,
            1.5
        ),

        math.clamp(
            enemyMaterial / 39,
            0,
            1.5
        ),

        math.clamp(
            (ownMaterial - enemyMaterial)
                / 39,
            -1.5,
            1.5
        ),

        math.clamp(
            ownCount / 16,
            0,
            1
        ),

        math.clamp(
            enemyCount / 16,
            0,
            1
        ),

        1,
    }

    for index = 1, 16 do
        features[
            128 + index
        ] =
            tonumber(extra[index])
            or 0
    end

    if #features
        ~= Config.NeuralInputSize then

        return nil
    end

    return features
end

Learning.Neural.QuantizeFeatures = function(features)
    if type(features) ~= "table"
        or #features
            ~= Config.NeuralInputSize then

        return nil
    end

    local quantized = {}

    for index = 1,
        Config.NeuralInputSize do

        local value =
            math.clamp(
                tonumber(
                    features[index]
                )
                or 0,
                -2,
                2
            )

        local scaled =
            value * 1000

        quantized[index] =
            scaled >= 0
            and math.floor(
                scaled + 0.5
            )
            or math.ceil(
                scaled - 0.5
            )
    end

    return quantized
end

Learning.Neural.DequantizeFeatures = function(quantized)
    if type(quantized) ~= "table"
        or #quantized
            ~= Config.NeuralInputSize then

        return nil
    end

    local features = {}

    for index = 1,
        Config.NeuralInputSize do

        features[index] =
            (
                tonumber(
                    quantized[index]
                )
                or 0
            )
            / 1000
    end

    return features
end

Learning.Neural.Forward = function(
    features,
    wantCache
)
    local model =
        Learning.Neural.model

    if not Learning.Neural.ValidateModel(
        model
    )
        or type(features) ~= "table"
        or #features
            ~= Config.NeuralInputSize then

        return 0,
            nil
    end

    local activation = features

    local cache =
        wantCache
        and {
            activations = {
                features,
            },
            pre = {},
        }
        or nil

    for layerIndex, layer in ipairs(
        model.layers
    ) do
        local output = {}

        local isOutputLayer =
            layerIndex
            == #model.layers

        local preLayer =
            wantCache
            and {}
            or nil

        for outIndex = 1,
            layer.outputSize do

            local sum =
                tonumber(
                    layer.bias[outIndex]
                )
                or 0

            local weightBase =
                (outIndex - 1)
                * layer.inputSize

            for inIndex = 1,
                layer.inputSize do

                sum +=
                    (
                        tonumber(
                            layer.weights[
                                weightBase
                                + inIndex
                            ]
                        )
                        or 0
                    )
                    * (
                        tonumber(
                            activation[
                                inIndex
                            ]
                        )
                        or 0
                    )
            end

            if preLayer then
                preLayer[
                    outIndex
                ] = sum
            end

            if isOutputLayer then
                output[outIndex] =
                    Learning.Neural.Tanh(
                        sum
                    )
            else
                output[outIndex] =
                    math.max(
                        0,
                        sum
                    )
            end
        end

        if wantCache then
            cache.pre[layerIndex] =
                preLayer

            cache.activations[
                layerIndex + 1
            ] =
                output
        end

        activation = output
    end

    return tonumber(
        activation[1]
    ) or 0,
        cache
end

Learning.Neural.PredictFeatures = function(features)
    if not Config.NeuralEnabled
        or not Learning.Neural.loaded then

        return 0
    end

    local value =
        Learning.Neural.Forward(
            features,
            false
        )

    return math.clamp(
        tonumber(value) or 0,
        -1,
        1
    )
end

Learning.Neural.PredictPosition = function(
    position,
    localTeam
)
    local features =
        Learning.Neural.ExtractFeatures(
            position,
            localTeam
        )

    if not features then
        return 0,
            nil
    end

    return Learning.Neural.PredictFeatures(
        features
    ),
        features
end

Learning.Neural.Confidence = function()
    if not Config.NeuralEnabled
        or not Learning.Neural.loaded then

        return 0
    end

    local updates =
        tonumber(
            Learning.Neural.stats.updates
        )
        or 0

    local replayCount =
        #Learning.Neural.replay.samples

    if updates
        < Config.NeuralMinUpdates
        or replayCount
            < Config.NeuralMinReplayForTraining then

        return 0
    end

    local updateProgress =
        math.clamp(
            (
                updates
                - Config.NeuralMinUpdates
            )
            / math.max(
                Config.NeuralFullInfluenceUpdates
                - Config.NeuralMinUpdates,
                1
            ),
            0,
            1
        )

    local replayProgress =
        math.clamp(
            replayCount / 300,
            0,
            1
        )

    return math.min(
        updateProgress,
        replayProgress
    )
end

Learning.Neural.AddReplay = function(
    features,
    nextFeatures,
    reward,
    done,
    target,
    priority,
    kind
)
    if not Config.NeuralEnabled
        or type(features) ~= "table" then

        return
    end

    local xq =
        Learning.Neural.QuantizeFeatures(
            features
        )

    if not xq then
        return
    end

    local sample = {
        x = xq,
        reward =
            tonumber(reward)
            or 0,
        done =
            done == true,
        priority =
            math.clamp(
                tonumber(priority)
                    or 1,
                0.05,
                8
            ),
        kind =
            tostring(
                kind
                or "td"
            ),
    }

    if type(nextFeatures) == "table" then
        sample.next =
            Learning.Neural.QuantizeFeatures(
                nextFeatures
            )
    end

    if target ~= nil then
        sample.target =
            math.clamp(
                tonumber(target)
                    or 0,
                -1,
                1
            )
    end

    local samples =
        Learning.Neural.replay.samples

    samples[
        #samples + 1
    ] = sample

    Learning.Neural.replay.added =
        (
            tonumber(
                Learning.Neural.replay.added
            )
            or 0
        )
        + 1

    while #samples
        > Config.NeuralReplayMax do

        table.remove(
            samples,
            1
        )
    end

    Learning.Neural.stats.samplesSeen =
        (
            tonumber(
                Learning.Neural.stats.samplesSeen
            )
            or 0
        )
        + 1

    Learning.Neural.dirtyReplay = true
    Learning.Neural.dirtyStats = true
end

Learning.Neural.SampleReplay = function()
    local samples =
        Learning.Neural.replay.samples

    if #samples == 0 then
        return nil
    end

    local total = 0

    for _, sample in ipairs(
        samples
    ) do
        total +=
            math.max(
                tonumber(
                    sample.priority
                )
                or 0.05,
                0.05
            )
    end

    if total <= 0 then
        return samples[
            math.random(
                1,
                #samples
            )
        ]
    end

    local needle =
        math.random()
        * total

    local cursor = 0

    for _, sample in ipairs(
        samples
    ) do
        cursor +=
            math.max(
                tonumber(
                    sample.priority
                )
                or 0.05,
                0.05
            )

        if cursor >= needle then
            return sample
        end
    end

    return samples[#samples]
end

Learning.Neural.TrainSample = function(sample)
    if type(sample) ~= "table" then
        return nil
    end

    local features =
        Learning.Neural.DequantizeFeatures(
            sample.x
        )

    if not features then
        return nil
    end

    local prediction, cache =
        Learning.Neural.Forward(
            features,
            true
        )

    if not cache then
        return nil
    end

    local target

    if sample.target ~= nil then
        target =
            math.clamp(
                tonumber(
                    sample.target
                )
                or 0,
                -1,
                1
            )
    else
        local bootstrap = 0

        if sample.done ~= true
            and type(sample.next)
                == "table" then

            local nextFeatures =
                Learning.Neural.DequantizeFeatures(
                    sample.next
                )

            if nextFeatures then
                bootstrap =
                    Learning.Neural.PredictFeatures(
                        nextFeatures
                    )
            end
        end

        target =
            math.clamp(
                (
                    tonumber(
                        sample.reward
                    )
                    or 0
                )
                + Config.NeuralGamma
                    * bootstrap,
                -1,
                1
            )
    end

    local error =
        prediction
        - target

    local absError =
        math.abs(
            error
        )

    local loss =
        absError <= 1
        and 0.5
            * error
            * error
        or absError - 0.5

    local lossGradient =
        absError <= 1
        and error
        or (
            error >= 0
            and 1
            or -1
        )

    local model =
        Learning.Neural.model

    local deltas = {}

    local outputDelta =
        lossGradient
        * (
            1
            - prediction
                * prediction
        )

    deltas[
        #model.layers
    ] = {
        math.clamp(
            outputDelta,
            -Config.NeuralGradientClip,
            Config.NeuralGradientClip
        ),
    }

    -- Build hidden deltas from the old weights BEFORE applying updates.
    for layerIndex =
        #model.layers,
        2,
        -1 do

        local layer =
            model.layers[
                layerIndex
            ]

        local previousLayer =
            model.layers[
                layerIndex - 1
            ]

        local currentDelta =
            deltas[
                layerIndex
            ]

        local previousActivation =
            cache.activations[
                layerIndex
            ]

        local previousDelta = {}

        for inIndex = 1,
            layer.inputSize do

            local sum = 0

            for outIndex = 1,
                layer.outputSize do

                local weightIndex =
                    (outIndex - 1)
                    * layer.inputSize
                    + inIndex

                sum +=
                    (
                        tonumber(
                            layer.weights[
                                weightIndex
                            ]
                        )
                        or 0
                    )
                    * (
                        tonumber(
                            currentDelta[
                                outIndex
                            ]
                        )
                        or 0
                    )
            end

            local reluDerivative =
                (
                    tonumber(
                        previousActivation[
                            inIndex
                        ]
                    )
                    or 0
                ) > 0
                and 1
                or 0

            previousDelta[
                inIndex
            ] =
                math.clamp(
                    sum
                        * reluDerivative,
                    -Config.NeuralGradientClip,
                    Config.NeuralGradientClip
                )
        end

        -- previousLayer exists to document/validate shape.
        if previousLayer then
            deltas[
                layerIndex - 1
            ] =
                previousDelta
        end
    end

    local learningRate =
        Config.NeuralLearningRate

    local weightDecay =
        Config.NeuralWeightDecay

    -- SGD update.
    for layerIndex, layer in ipairs(
        model.layers
    ) do
        local inputActivation =
            cache.activations[
                layerIndex
            ]

        local delta =
            deltas[
                layerIndex
            ]

        for outIndex = 1,
            layer.outputSize do

            local d =
                math.clamp(
                    tonumber(
                        delta[
                            outIndex
                        ]
                    )
                    or 0,
                    -Config.NeuralGradientClip,
                    Config.NeuralGradientClip
                )

            local weightBase =
                (outIndex - 1)
                * layer.inputSize

            for inIndex = 1,
                layer.inputSize do

                local weightIndex =
                    weightBase
                    + inIndex

                local oldWeight =
                    tonumber(
                        layer.weights[
                            weightIndex
                        ]
                    )
                    or 0

                local gradient =
                    d
                    * (
                        tonumber(
                            inputActivation[
                                inIndex
                            ]
                        )
                        or 0
                    )

                gradient =
                    math.clamp(
                        gradient,
                        -Config.NeuralGradientClip,
                        Config.NeuralGradientClip
                    )

                layer.weights[
                    weightIndex
                ] =
                    math.clamp(
                        oldWeight
                        - learningRate
                            * gradient
                        - learningRate
                            * weightDecay
                            * oldWeight,
                        -5,
                        5
                    )
            end

            layer.bias[outIndex] =
                math.clamp(
                    (
                        tonumber(
                            layer.bias[
                                outIndex
                            ]
                        )
                        or 0
                    )
                    - learningRate
                        * d,
                    -5,
                    5
                )
        end
    end

    sample.priority =
        math.clamp(
            absError
                + 0.08,
            0.05,
            8
        )

    Learning.Neural.dirtyWeights = true
    Learning.Neural.dirtyReplay = true

    return loss,
        error,
        target,
        prediction
end

Learning.Neural.TrainBatch = function()
    if not Config.NeuralEnabled
        or Learning.Neural.training then

        return nil
    end

    if #Learning.Neural.replay.samples
        < Config.NeuralMinReplayForTraining then

        return nil
    end

    Learning.Neural.training = true

    local startedAt =
        os.clock()

    local totalLoss = 0
    local trained = 0

    for _ = 1,
        Config.NeuralBatchSize do

        local sample =
            Learning.Neural.SampleReplay()

        if sample then
            local loss =
                Learning.Neural.TrainSample(
                    sample
                )

            if loss then
                totalLoss += loss
                trained += 1
            end
        end
    end

    Learning.Neural.training = false

    if trained <= 0 then
        return nil
    end

    local avgLoss =
        totalLoss
        / trained

    local stats =
        Learning.Neural.stats

    stats.updates =
        (
            tonumber(stats.updates)
            or 0
        )
        + 1

    stats.lastLoss =
        avgLoss

    stats.avgLoss =
        (
            tonumber(stats.avgLoss)
            or 0
        ) == 0
        and avgLoss
        or (
            tonumber(stats.avgLoss)
            * 0.94
            + avgLoss
                * 0.06
        )

    stats.lastTrainSeconds =
        os.clock()
        - startedAt

    Learning.Neural.dirtyStats = true

    Learning.Neural.Save(false)

    return avgLoss
end

Learning.Neural.TrainBatches = function(
    batchCount,
    reason
)
    if not Config.NeuralEnabled
        or Learning.Neural.training
        or Learning.Neural.jobRunning then

        return
    end

    batchCount =
        math.max(
            math.floor(
                tonumber(batchCount)
                or 0
            ),
            0
        )

    if batchCount <= 0 then
        return
    end

    Learning.Neural.jobRunning =
        true

    task.spawn(
        function()
            local losses = {}
            local startedAt =
                os.clock()

            for _ = 1, batchCount do
                -- Do not let background training compete with a new live game.
                local live =
                    GetCurrentMatch()

                if live then
                    break
                end

                local okTrain,
                    lossOrError =
                    pcall(
                        Learning.Neural.TrainBatch
                    )

                if not okTrain then
                    Learning.Neural.training =
                        false

                    LearningLog(
                        "NEURAL_TRAIN_ERROR "
                        .. tostring(
                            lossOrError
                        )
                    )

                    break
                end

                if lossOrError then
                    losses[
                        #losses + 1
                    ] =
                        lossOrError
                end

                task.wait()
            end

            Learning.Neural.training =
                false

            Learning.Neural.jobRunning =
                false

            if #losses > 0 then
                local sum = 0

                for _, loss in ipairs(
                    losses
                ) do
                    sum += loss
                end

                LearningLog(
                    string.format(
                        "NEURAL_TRAIN reason=%s batches=%d loss=%.5f replay=%d updates=%d time=%.2fs confidence=%.1f%%",
                        tostring(
                            reason or "?"
                        ),
                        #losses,
                        sum / #losses,
                        #Learning.Neural.replay.samples,
                        tonumber(
                            Learning.Neural.stats.updates
                        ) or 0,
                        os.clock() - startedAt,
                        Learning.Neural.Confidence()
                            * 100
                    )
                )

                Learning.Neural.Save(true)
            end
        end
    )
end

Learning.Neural.IdleTick = function(match)
    if not Config.NeuralEnabled
        or match ~= nil
        or Learning.Neural.training
        or Learning.Neural.jobRunning then

        return
    end

    local now =
        os.clock()

    if now
        - Learning.Neural.lastIdleTrain
        < Config.NeuralIdleInterval then

        return
    end

    Learning.Neural.lastIdleTrain =
        now

    if #Learning.Neural.replay.samples
        >= Config.NeuralMinReplayForTraining then

        Learning.Neural.TrainBatches(
            Config.NeuralIdleBatches,
            "lobby"
        )
    end
end

Learning.Neural.MoveBias = function(
    position,
    move,
    localTeam
)
    local confidence =
        Learning.Neural.Confidence()

    if confidence <= 0
        or type(position) ~= "table"
        or type(move) ~= "table"
        or type(localTeam) ~= "boolean" then

        return 0,
            0,
            confidence
    end

    local okNext, nextPosition =
        pcall(function()
            return position:move(
                move
            )
        end)

    if not okNext
        or type(nextPosition) ~= "table" then

        return 0,
            0,
            confidence
    end

    local value =
        Learning.Neural.PredictPosition(
            nextPosition,
            localTeam
        )

    local bias =
        value
        * Config.NeuralInfluenceCp
        * confidence

    return bias,
        value,
        confidence
end

Learning.Neural.RerankAutomatic = function(
    match,
    position,
    localTeam,
    selectedMove,
    info
)
    local confidence =
        Learning.Neural.Confidence()

    if confidence <= 0
        or type(info) ~= "table"
        or type(info.candidates)
            ~= "table"
        or type(selectedMove)
            ~= "table" then

        return selectedMove,
            info
    end

    local pool = {}
    local seen = {}

    local function add(
        move,
        score,
        source
    )
        if type(move) ~= "table" then
            return
        end

        local key =
            MoveIdentity(move)

        if seen[key] then
            return
        end

        if not ResolveGameMove(
            match,
            move,
            position,
            localTeam
        ) then
            return
        end

        seen[key] = true

        local neuralBias,
            neuralValue =
            Learning.Neural.MoveBias(
                position,
                move,
                localTeam
            )

        local memoryBias =
            LearningOwnMoveBias(
                position,
                move
            )

        pool[
            #pool + 1
        ] = {
            move = move,
            base =
                tonumber(score)
                or 0,
            neuralBias =
                neuralBias,
            neuralValue =
                neuralValue,
            memoryBias =
                memoryBias,
            source =
                source,
        }
    end

    add(
        selectedMove,
        info.score,
        "selected"
    )

    for index, candidate in ipairs(
        info.candidates
    ) do
        add(
            candidate.move,
            candidate.score,
            "candidate"
        )

        if index
            >= Config.NeuralAutomaticCandidates then

            break
        end
    end

    if #pool <= 1 then
        return selectedMove,
            info
    end

    for _, entry in ipairs(pool) do
        entry.total =
            entry.base
            + entry.neuralBias
            + entry.memoryBias
    end

    table.sort(
        pool,
        function(a, b)
            return a.total
                > b.total
        end
    )

    local winner =
        pool[1]

    local current

    for _, entry in ipairs(pool) do
        if MoveIdentity(entry.move)
            == MoveIdentity(
                selectedMove
            ) then

            current = entry
            break
        end
    end

    current =
        current
        or winner

    info.neural = {
        confidence =
            confidence,
        value =
            winner.neuralValue,
        bias =
            winner.neuralBias,
        memoryBias =
            winner.memoryBias,
        changed =
            MoveIdentity(
                winner.move
            ) ~= MoveIdentity(
                selectedMove
            ),
    }

    -- Require a small margin so low-confidence noise does not flip
    -- effectively-equal candidates every move.
    if winner.total
        > current.total + 12
        and info.neural.changed then

        SetThinkingNarrative(
            string.format(
                "Neural rerank: %.0f%% confidence • value %+.2f • bias %+d.",
                confidence * 100,
                winner.neuralValue,
                math.floor(
                    winner.neuralBias
                )
            ),
            "thinking"
        )

        return winner.move,
            info
    end

    return selectedMove,
        info
end

Learning.Neural.RecordOwnTurnState = function(
    session,
    features
)
    if type(session) ~= "table"
        or type(features) ~= "table" then

        return
    end

    if session.neuralPendingState then
        Learning.Neural.AddReplay(
            session.neuralPendingState,
            features,
            0,
            false,
            nil,
            0.35,
            "td-fullply"
        )
    end

    session.neuralPendingState =
        features

    session.neuralTrajectory[
        #session.neuralTrajectory + 1
    ] =
        features
end

Learning.Neural.FinalizeGame = function(
    session,
    result,
    reason
)
    if not Config.NeuralEnabled
        or type(session) ~= "table" then

        return
    end

    local outcome =
        result == "win"
        and 1
        or result == "loss"
        and -1
        or result == "draw"
        and 0
        or nil

    if outcome == nil then
        return
    end

    local stats =
        Learning.Neural.stats

    stats.games =
        (
            tonumber(stats.games)
            or 0
        )
        + 1

    if result == "win" then
        stats.wins =
            (tonumber(stats.wins) or 0)
            + 1
    elseif result == "loss" then
        stats.losses =
            (tonumber(stats.losses) or 0)
            + 1
    elseif result == "draw" then
        stats.draws =
            (tonumber(stats.draws) or 0)
            + 1
    else
        stats.unknown =
            (tonumber(stats.unknown) or 0)
            + 1
    end

    Learning.Neural.dirtyStats = true

    -- Terminal TD sample for the last state where it was our turn.
    if session.neuralPendingState then
        Learning.Neural.AddReplay(
            session.neuralPendingState,
            nil,
            outcome,
            true,
            outcome,
            2.2,
            "terminal"
        )
    end

    local trajectory =
        session.neuralTrajectory

    local count =
        #trajectory

    local isRepetition =
        result == "draw"
        and (
            session.repetitionDraw
            or string.find(
                string.lower(
                    tostring(
                        reason or ""
                    )
                ),
                "repetition",
                1,
                true
            ) ~= nil
        )

    for index, features in ipairs(
        trajectory
    ) do
        local distance =
            count - index

        local target =
            outcome
            * (
                Config.NeuralGamma
                ^ distance
            )

        local priority =
            0.70
            + 0.90
                * math.exp(
                    -distance / 6
                )

        if isRepetition
            and distance <= 6 then

            priority += 1.3
        end

        Learning.Neural.AddReplay(
            features,
            nil,
            0,
            true,
            target,
            priority,
            isRepetition
                and "mc-repetition"
                or "mc-outcome"
        )
    end

    LearningLog(
        string.format(
            "NEURAL_GAME result=%s reason=%s trajectory=%d replay=%d",
            tostring(result),
            tostring(reason or "?"),
            count,
            #Learning.Neural.replay.samples
        )
    )

    Learning.Neural.Save(true)

    task.delay(
        0.65,
        function()
            Learning.Neural.TrainBatches(
                Config.NeuralEndGameBatches,
                "post-game "
                    .. tostring(result)
            )
        end
    )
end

LearningLoad()
Learning.Neural.Load()

-- Supplement result detection with the game's EndGame event.
--
-- Confirmed from live logs:
--   arg1 boolean = winning team
--   arg2 string  = termination reason (e.g. "checkmate")
--
-- Explicit draw strings still take precedence over the winner-team boolean.
do
    local endGameRemote =
        Connections:FindFirstChild(
            "EndGame"
        )

    if endGameRemote
        and endGameRemote:IsA(
            "RemoteEvent"
        ) then

        endGameRemote.OnClientEvent:Connect(
            function(...)
                local session =
                    Learning.session

                if not session
                    or session.finalized then

                    return
                end

                session.endRemoteSeen = true

                local args = {
                    ...,
                }

                local tokens = {}
                local winnerTeam = nil
                local explicitResult = nil
                local reasonText = nil

                local function inspect(value)
                    local kind =
                        typeof(value)

                    if kind == "string"
                        or kind == "number"
                        or kind == "boolean" then

                        tokens[
                            #tokens + 1
                        ] =
                            tostring(value)
                    end

                    if kind == "boolean"
                        and winnerTeam == nil then

                        winnerTeam = value
                        return
                    end

                    if kind == "string" then
                        local lower =
                            string.lower(value)

                        if reasonText == nil then
                            reasonText = value
                        end

                        if value == "½-½"
                            or lower == "1/2-1/2"
                            or string.find(lower, "draw", 1, true)
                            or string.find(lower, "remis", 1, true)
                            or string.find(lower, "stalemate", 1, true)
                            or string.find(lower, "repetition", 1, true)
                            or string.find(lower, "fifty", 1, true) then

                            explicitResult = "draw"
                            reasonText = value

                        elseif value == "1-0"
                            and type(session.localTeam)
                                == "boolean" then

                            explicitResult =
                                session.localTeam
                                and "win"
                                or "loss"

                            reasonText = value

                        elseif value == "0-1"
                            and type(session.localTeam)
                                == "boolean" then

                            explicitResult =
                                not session.localTeam
                                and "win"
                                or "loss"

                            reasonText = value
                        end

                    elseif kind == "table" then
                        for _, key in ipairs({
                            "winner",
                            "winnerTeam",
                            "team",
                            "result",
                            "victoryType",
                            "reason",
                            "termination",
                        }) do
                            if value[key] ~= nil then
                                inspect(value[key])
                            end
                        end
                    end
                end

                for _, value in ipairs(
                    args
                ) do
                    inspect(value)
                end

                if explicitResult then
                    session.resultHint =
                        explicitResult

                elseif type(winnerTeam)
                    == "boolean"
                    and type(session.localTeam)
                        == "boolean" then

                    session.resultHint =
                        winnerTeam
                            == session.localTeam
                        and "win"
                        or "loss"
                end

                if reasonText then
                    session.resultReason =
                        reasonText
                elseif winnerTeam ~= nil then
                    session.resultReason =
                        "winnerTeam="
                        .. tostring(
                            winnerTeam
                        )
                end

                LearningLog(
                    string.format(
                        "ENDGAME_REMOTE %s => hint=%s localTeam=%s winnerTeam=%s",
                        table.concat(
                            tokens,
                            " | "
                        ),
                        tostring(
                            session.resultHint
                        ),
                        tostring(
                            session.localTeam
                        ),
                        tostring(
                            winnerTeam
                        )
                    )
                )
            end
        )
    end
end

--// ============================================================
--// v4.8 MIDGAME FEN/HISTORY REPLAY
--// ============================================================

local PromotionNameFromFEN = {
    Q = "Queen",
    R = "Rook",
    B = "Bishop",
    N = "Knight",
}

local function IsFENString(value)
    return type(value) == "string"
        and string.find(
            value,
            "/",
            1,
            true
        ) ~= nil
end

local function SplitWords(text)
    local words = {}

    for word in string.gmatch(
        tostring(text or ""),
        "%S+"
    ) do
        words[#words + 1] = word
    end

    return words
end

local function ParseFEN(fen)
    if not IsFENString(fen) then
        return nil
    end

    local fields =
        SplitWords(fen)

    local placement =
        fields[1]

    if not placement then
        return nil
    end

    local ranks = {}

    for rank in string.gmatch(
        placement,
        "[^/]+"
    ) do
        ranks[#ranks + 1] = rank
    end

    if #ranks ~= 8 then
        return nil
    end

    local board = {}

    for x = 1, 8 do
        board[x] = {}
    end

    -- FEN rank order is 8 -> 1 and files are a -> h.
    -- Game coordinates are mirrored on X:
    --   a-file = x8, h-file = x1.
    for fenRankIndex = 1, 8 do
        local rankText =
            ranks[fenRankIndex]

        local y =
            9 - fenRankIndex

        local fileIndex = 1

        for i = 1, #rankText do
            local char =
                string.sub(
                    rankText,
                    i,
                    i
                )

            local digit =
                tonumber(char)

            if digit then
                fileIndex += digit
            else
                if fileIndex < 1
                    or fileIndex > 8 then

                    return nil
                end

                local x =
                    9 - fileIndex

                board[x][y] = char
                fileIndex += 1
            end
        end

        if fileIndex ~= 9 then
            return nil
        end
    end

    return {
        raw = fen,
        placement = placement,
        active =
            fields[2]
            or "w",
        board = board,
    }
end

local function FENPieceIsTeam(
    char,
    team
)
    if type(char) ~= "string"
        or #char ~= 1 then

        return false
    end

    if not string.match(
        char,
        "[prnbqkPRNBQK]"
    ) then

        return false
    end

    local upper =
        string.upper(char)

    local isWhite =
        char == upper

    return isWhite == team
end

local function InferMoveFromFEN(
    beforeFEN,
    afterFEN,
    movingTeam
)
    local before =
        ParseFEN(beforeFEN)

    local after =
        ParseFEN(afterFEN)

    if not before or not after then
        return nil,
            "FEN PARSE FAILED"
    end

    local sources = {}
    local destinations = {}

    for x = 1, 8 do
        for y = 1, 8 do
            local old =
                before.board[x][y]

            local new =
                after.board[x][y]

            if old ~= new then
                if FENPieceIsTeam(
                    old,
                    movingTeam
                ) then

                    sources[#sources + 1] = {
                        x = x,
                        y = y,
                        char = old,
                    }
                end

                if FENPieceIsTeam(
                    new,
                    movingTeam
                ) then

                    destinations[
                        #destinations + 1
                    ] = {
                        x = x,
                        y = y,
                        char = new,
                    }
                end
            end
        end
    end

    -- Castling changes both King and Rook. Select the King pair.
    if #sources >= 2
        and #destinations >= 2 then

        local kingChar =
            movingTeam
            and "K"
            or "k"

        local kingSource
        local kingDestination

        for _, item in ipairs(sources) do
            if item.char == kingChar then
                kingSource = item
                break
            end
        end

        for _, item in ipairs(destinations) do
            if item.char == kingChar then
                kingDestination = item
                break
            end
        end

        if kingSource
            and kingDestination then

            return {
                from = {
                    kingSource.x,
                    kingSource.y,
                },

                to = {
                    kingDestination.x,
                    kingDestination.y,
                },

                promote = nil,
                kind = "castling",
            }
        end
    end

    if #sources < 1
        or #destinations < 1 then

        return nil,
            string.format(
                "FEN DIFF AMBIGUOUS src=%d dst=%d",
                #sources,
                #destinations
            )
    end

    local source

    -- Promotion/en-passant/normal moves still have one moving source.
    -- If multiple candidates somehow remain, prefer a Pawn source,
    -- otherwise the first candidate.
    if #sources == 1 then
        source = sources[1]
    else
        local pawnChar =
            movingTeam
            and "P"
            or "p"

        for _, item in ipairs(sources) do
            if item.char == pawnChar then
                source = item
                break
            end
        end

        source =
            source
            or sources[1]
    end

    local destination

    if #destinations == 1 then
        destination =
            destinations[1]
    else
        -- Prefer a destination whose piece differs from the source type.
        -- This catches promotion.
        for _, item in ipairs(destinations) do
            if string.upper(item.char)
                ~= string.upper(
                    source.char
                ) then

                destination = item
                break
            end
        end

        destination =
            destination
            or destinations[1]
    end

    local promotion

    if string.upper(source.char) == "P"
        and string.upper(
            destination.char
        ) ~= "P" then

        promotion =
            string.upper(
                destination.char
            )
    end

    return {
        from = {
            source.x,
            source.y,
        },

        to = {
            destination.x,
            destination.y,
        },

        promote = promotion,
        kind =
            promotion
            and "promotion"
            or "normal",
    }
end

local function GetLiveFEN(match)
    if type(match) ~= "table" then
        return nil
    end

    local ok, fen =
        pcall(function()
            if type(
                match.createFENLine
            ) == "function" then

                return match:createFENLine()
            end

            if type(
                GameBoard.createFENLine
            ) == "function" then

                return GameBoard.createFENLine(
                    match
                )
            end
        end)

    if ok
        and IsFENString(fen) then

        return fen
    end

    return nil
end

local function CollectFENHistory(match)
    local history = {}

    local function append(fen)
        if not IsFENString(fen) then
            return
        end

        if history[#history] ~= fen then
            history[#history + 1] =
                fen
        end
    end

    append(match.startFEN)

    local states =
        match.boardStates

    if type(states) == "table" then
        -- Board.nextRound stores states in an array on the client.
        -- Prefer numeric order. Also support table-wrapped FENs.
        local numericKeys = {}

        for key in pairs(states) do
            if type(key) == "number" then
                numericKeys[
                    #numericKeys + 1
                ] = key
            end
        end

        table.sort(numericKeys)

        for _, key in ipairs(
            numericKeys
        ) do
            local state =
                states[key]

            if type(state) == "string" then
                append(state)

            elseif type(state) == "table" then
                append(
                    state.fen
                    or state.FEN
                    or state[1]
                )
            end
        end
    end

    append(
        GetLiveFEN(match)
    )

    return history
end


--// ============================================================
--// v5.1 LEARNING FROM BOARD HISTORY
--// ============================================================

Learning.CanonicalRepetitionFEN = function(fen)
    if not IsFENString(fen) then
        return nil
    end

    local fields = {}

    for word in string.gmatch(
        fen,
        "%S+"
    ) do
        fields[#fields + 1] = word
    end

    if #fields < 1 then
        return nil
    end

    return table.concat({
        fields[1] or "",
        fields[2] or "",
        fields[3] or "-",
        fields[4] or "-",
    }, " ")
end

Learning.ProcessHistory = function(match)
    local session =
        Learning.session

    if not session
        or session.matchId
            ~= match.id then

        return
    end

    local history =
        CollectFENHistory(match)

    if #history < 1 then
        return
    end

    if session.historyIndex <= 0
        or session.historyFirstFEN
            ~= history[1]
        or type(session.historyPosition)
            ~= "table" then

        local first =
            ParseFEN(history[1])

        if not first
            or first.placement
                ~= "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR" then

            return
        end

        local okCreate, position =
            pcall(
                Sunfish.createPosition,
                Sunfish.initial
            )

        if not okCreate
            or type(position) ~= "table" then

            return
        end

        session.historyIndex = 1
        session.historyFirstFEN = history[1]
        session.historyPosition = position

        session.repetitionCounts = {}
        session.sunfishVisits = {}

        local firstKey =
            Learning.CanonicalRepetitionFEN(
                history[1]
            )

        if firstKey then
            session.repetitionCounts[firstKey] = 1
        end

        local sunfishKey =
            LearningPositionKey(position)

        if sunfishKey then
            session.sunfishVisits[sunfishKey] = 1
        end

        if Config.NeuralEnabled
            and type(session.localTeam)
                == "boolean"
            and position.player
                == session.localTeam then

            local features =
                Learning.Neural.ExtractFeatures(
                    position,
                    session.localTeam
                )

            if features then
                session.neuralPendingState =
                    features

                session.neuralTrajectory[
                    #session.neuralTrajectory + 1
                ] =
                    features
            end
        end
    end

    if #history < session.historyIndex then
        session.historyIndex = 0
        session.historyPosition = nil
        return
    end

    local position =
        session.historyPosition

    for index =
        session.historyIndex + 1,
        #history do

        local beforeFEN =
            history[index - 1]

        local afterFEN =
            history[index]

        local inferred =
            InferMoveFromFEN(
                beforeFEN,
                afterFEN,
                position.player
            )

        if not inferred then
            break
        end

        local toMove = {
            inferred.to[1],
            inferred.to[2],
        }

        if inferred.promote then
            local pieceName =
                PromotionNameFromFEN[
                    inferred.promote
                ]

            if pieceName then
                toMove.promote = {
                    pieceName = pieceName,
                }
            end
        end

        local sunfishMove =
            MatchMoveToSunfish(
                position,
                inferred.from,
                toMove
            )

        if not sunfishMove then
            break
        end

        if type(session.localTeam) == "boolean"
            and position.player
                ~= session.localTeam then

            -- Works for PvP AND built-in Sunfish bot games.
            LearningRecordTeacherMove(
                match,
                position,
                sunfishMove
            )
        end

        local okMove, nextPosition =
            pcall(function()
                return position:move(
                    sunfishMove
                )
            end)

        if not okMove
            or type(nextPosition) ~= "table" then

            break
        end

        position = nextPosition
        session.historyPosition = position
        session.historyIndex = index

        if Config.NeuralEnabled
            and type(session.localTeam)
                == "boolean"
            and position.player
                == session.localTeam then

            local features =
                Learning.Neural.ExtractFeatures(
                    position,
                    session.localTeam
                )

            if features then
                Learning.Neural.RecordOwnTurnState(
                    session,
                    features
                )
            end
        end

        local repetitionKey =
            Learning.CanonicalRepetitionFEN(
                afterFEN
            )

        if repetitionKey then
            local count =
                (
                    tonumber(
                        session.repetitionCounts[
                            repetitionKey
                        ]
                    )
                    or 0
                )
                + 1

            session.repetitionCounts[
                repetitionKey
            ] = count

            if count >= 3 then
                session.repetitionDraw = true
                session.repetitionKey = repetitionKey
                session.resultHint = "draw"
                session.resultReason = "repetition"
            end
        end

        local sunfishKey =
            LearningPositionKey(position)

        if sunfishKey then
            session.sunfishVisits[
                sunfishKey
            ] =
                (
                    tonumber(
                        session.sunfishVisits[
                            sunfishKey
                        ]
                    )
                    or 0
                )
                + 1
        end
    end

    if (
        tonumber(match.fiftyMoveCounter)
        or 0
    ) >= 100 then

        session.resultHint = "draw"
        session.resultReason = "fiftymoves"
    end
end

Learning.ProcessBotLiveLearning = function(match)
    local session =
        Learning.session

    if not session
        or session.matchId ~= match.id
        or match.mode ~= "sunfish"
        or type(session.localTeam) ~= "boolean" then

        return
    end

    local liveFEN =
        GetLiveFEN(match)

    local activeTeam =
        match.activeTeam

    if type(activeTeam) ~= "boolean"
        or not liveFEN then

        return
    end

    if activeTeam
        ~= session.localTeam then

        -- Opponent/bot is thinking. Snapshot the exact pre-reply state.
        if not session.botTeacherPendingFEN
            or session.botTeacherPendingFEN
                ~= liveFEN then

            local position =
                match.sunfishPos

            if type(position) == "table"
                and type(position.player)
                    == "boolean"
                and position.player
                    == activeTeam then

                session.botTeacherPendingFEN =
                    liveFEN

                session.botTeacherPendingPosition =
                    position
            end
        end

        return
    end

    -- We are to move again: if a bot snapshot exists, infer the reply.
    local beforeFEN =
        session.botTeacherPendingFEN

    local beforePosition =
        session.botTeacherPendingPosition

    if beforeFEN
        and type(beforePosition)
            == "table"
        and beforeFEN ~= liveFEN then

        local inferred =
            InferMoveFromFEN(
                beforeFEN,
                liveFEN,
                beforePosition.player
            )

        if inferred then
            local toMove = {
                inferred.to[1],
                inferred.to[2],
            }

            if inferred.promote then
                local pieceName =
                    PromotionNameFromFEN[
                        inferred.promote
                    ]

                if pieceName then
                    toMove.promote = {
                        pieceName =
                            pieceName,
                    }
                end
            end

            local sunfishMove =
                MatchMoveToSunfish(
                    beforePosition,
                    inferred.from,
                    toMove
                )

            if sunfishMove then
                LearningRecordTeacherMove(
                    match,
                    beforePosition,
                    sunfishMove
                )

                LearningLog(
                    "BOT_TEACHER_LIVE "
                    .. LearningMoveId(
                        sunfishMove
                    )
                )
            else
                LearningLog(
                    "BOT_TEACHER_LIVE_FAIL map"
                )
            end
        else
            LearningLog(
                "BOT_TEACHER_LIVE_FAIL diff"
            )
        end

        session.botTeacherPendingFEN =
            nil

        session.botTeacherPendingPosition =
            nil
    end

    -- Feed a stable OUR-turn position into the neural full-ply trajectory.
    if Config.NeuralEnabled
        and type(
            Learning.Neural
        ) == "table"
        and type(
            Learning.Neural.ExtractFeatures
        ) == "function"
        and type(match.sunfishPos)
            == "table"
        and match.sunfishPos.player
            == session.localTeam then

        local positionKey =
            LearningPositionKey(
                match.sunfishPos
            )

        if positionKey
            and positionKey
                ~= session.botLastNeuralKey then

            local features =
                Learning.Neural.ExtractFeatures(
                    match.sunfishPos,
                    session.localTeam
                )

            if features then
                session.botLastNeuralKey =
                    positionKey

                Learning.Neural.RecordOwnTurnState(
                    session,
                    features
                )
            end
        end
    end
end

Learning.RepetitionRisk = function(
    position,
    move
)
    local session =
        Learning.session

    if not session
        or type(position) ~= "table"
        or type(move) ~= "table" then

        return 0
    end

    local okNext, nextPosition =
        pcall(function()
            return position:move(move)
        end)

    if not okNext
        or type(nextPosition) ~= "table" then

        return 0
    end

    local key =
        LearningPositionKey(nextPosition)

    if not key then
        return 0
    end

    return tonumber(
        session.sunfishVisits[key]
    ) or 0
end

Learning.ApplyRepetitionGuard = function(
    match,
    position,
    selectedMove,
    info
)
    if not Config.LearningEnabled
        or type(selectedMove) ~= "table"
        or type(position) ~= "table" then

        return selectedMove, info
    end

    local risk =
        Learning.RepetitionRisk(
            position,
            selectedMove
        )

    if risk < 2 then
        return selectedMove, info
    end

    local score =
        tonumber(
            info
            and info.score
        )
        or 0

    -- When clearly losing, repetition is allowed as a defensive resource.
    if score
        <= -Config.LearningRepetitionAvoidEval then

        return selectedMove, info
    end

    local candidates =
        info
        and info.candidates

    if type(candidates) == "table" then
        local team =
            GetLocalTeam(match)

        for _, candidate in ipairs(candidates) do
            local move =
                candidate.move

            if type(move) == "table"
                and MoveIdentity(move)
                    ~= MoveIdentity(selectedMove)
                and Learning.RepetitionRisk(
                    position,
                    move
                ) < 2
                and ResolveGameMove(
                    match,
                    move,
                    position,
                    team
                ) then

                LearningLog(
                    string.format(
                        "REPETITION_VETO id=%s old=%s new=%s eval=%+.2f",
                        tostring(match.id),
                        LearningMoveId(selectedMove),
                        LearningMoveId(move),
                        score / 100
                    )
                )

                SetThinkingNarrative(
                    "Learning Memory: bác nước dẫn tới lặp lần 3 khi đang không thua.",
                    "warning"
                )

                return move, info
            end
        end
    end

    return selectedMove, info
end

local function StandardInitialPlacement()
    local parsed =
        ParseFEN(
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        )

    return parsed
        and parsed.placement
        or nil
end

local STANDARD_INITIAL_PLACEMENT =
    StandardInitialPlacement()

local function ReplayShadowFromHistory(match)
    if type(match) ~= "table" then
        return nil,
            "NO MATCH"
    end

    local history =
        CollectFENHistory(
            match
        )

    if #history < 1 then
        return nil,
            "NO FEN HISTORY"
    end

    local first =
        ParseFEN(
            history[1]
        )

    if not first then
        return nil,
            "START FEN INVALID"
    end

    -- The PvP/Ranked matches in this game use the standard start.
    -- Do not silently invent an incorrect score for custom midgame FEN.
    if first.placement
        ~= STANDARD_INITIAL_PLACEMENT then

        return nil,
            "CUSTOM START FEN UNSUPPORTED"
    end

    local okCreate, position =
        pcall(
            Sunfish.createPosition,
            Sunfish.initial
        )

    if not okCreate
        or type(position) ~= "table" then

        return nil,
            "CREATE INITIAL POSITION FAILED"
    end

    local plies = 0

    for index = 2, #history do
        local beforeFEN =
            history[index - 1]

        local afterFEN =
            history[index]

        local inferred,
            inferError =
            InferMoveFromFEN(
                beforeFEN,
                afterFEN,
                position.player
            )

        if not inferred then
            return nil,
                string.format(
                    "REPLAY DIFF FAILED @%d: %s",
                    index - 1,
                    tostring(inferError)
                )
        end

        local toMove = {
            inferred.to[1],
            inferred.to[2],
        }

        if inferred.promote then
            local pieceName =
                PromotionNameFromFEN[
                    inferred.promote
                ]

            if pieceName then
                toMove.promote = {
                    pieceName =
                        pieceName,
                }
            end
        end

        local sunfishMove =
            MatchMoveToSunfish(
                position,
                inferred.from,
                toMove
            )

        if not sunfishMove then
            return nil,
                string.format(
                    "REPLAY MOVE NOT FOUND @%d (%d,%d -> %d,%d)",
                    index - 1,
                    inferred.from[1],
                    inferred.from[2],
                    inferred.to[1],
                    inferred.to[2]
                )
        end

        local okMove, nextPosition =
            pcall(function()
                return position:move(
                    sunfishMove
                )
            end)

        if not okMove
            or type(nextPosition)
                ~= "table" then

            return nil,
                string.format(
                    "REPLAY POSITION FAILED @%d",
                    index - 1
                )
        end

        position =
            nextPosition

        plies += 1

        -- Keep long midgame reconstruction responsive on mobile.
        if plies % 8 == 0 then
            task.wait()
        end
    end

    -- Sanity: side-to-move should agree with game state.
    if type(match.activeTeam) == "boolean"
        and position.player
            ~= match.activeTeam then

        return nil,
            string.format(
                "REPLAY TURN MISMATCH engine=%s game=%s",
                tostring(position.player),
                tostring(match.activeTeam)
            )
    end

    return position,
        nil,
        plies
end

local function AttemptShadowResync(
    match,
    reason
)
    if type(match) ~= "table"
        or match.mode == "sunfish" then

        return false,
            "RESYNC NOT NEEDED"
    end

    local position,
        replayError,
        plies =
        ReplayShadowFromHistory(
            match
        )

    if not position then
        Shadow.ready = false

        Shadow.reason =
            "RESYNC FAILED: "
            .. tostring(
                replayError
            )

        return false,
            Shadow.reason
    end

    Shadow.matchId = match.id
    Shadow.position = position
    Shadow.ready = true

    Shadow.pendingKey = nil
    Shadow.pendingUntil = 0

    Shadow.historyPlies =
        plies or 0

    Shadow.lastSyncMethod =
        "FEN_HISTORY"

    Shadow.reason =
        string.format(
            "RESYNCED • %d plies",
            Shadow.historyPlies
        )

    return true,
        Shadow.reason
end

local function ScheduleShadowResync(
    match,
    reason
)
    if type(match) ~= "table"
        or match.mode == "sunfish" then

        return
    end

    Shadow.resyncToken += 1

    local token =
        Shadow.resyncToken

    Shadow.ready = false

    Shadow.reason =
        "RESYNCING: "
        .. tostring(reason)

    local matchId =
        match.id

    local function tryAfter(delaySeconds)
        task.delay(
            delaySeconds,
            function()
                if token
                    ~= Shadow.resyncToken then

                    return
                end

                local live =
                    GetCurrentMatch()

                if not live
                    or live.id
                        ~= matchId then

                    return
                end

                local ok =
                    AttemptShadowResync(
                        live,
                        reason
                    )

                if ok then
                    SetThinkingNarrative(
                        string.format(
                            "Shadow đã tự đồng bộ lại từ board history (%d plies).",
                            Shadow.historyPlies
                        ),
                        "decision"
                    )

                    SetStatus(
                        "SHADOW RESYNCED",
                        false
                    )
                end
            end
        )
    end

    -- First attempt after MatchClient has had time to update boardStates.
    tryAfter(0.12)

    -- Race-condition fallback for slower network/client bookkeeping.
    tryAfter(0.42)
end

local function ResetShadow(match)
    Shadow.matchId =
        match and match.id or nil

    Shadow.position = nil
    Shadow.ready = false
    Shadow.reason = "SYNC REQUIRED"

    Shadow.pendingKey = nil
    Shadow.pendingUntil = 0

    Shadow.resyncToken += 1
    Shadow.historyPlies = 0
    Shadow.lastSyncMethod = nil

    if not match then
        return
    end

    if match.mode == "sunfish"
        and type(match.sunfishPos) == "table" then

        Shadow.reason = "GAME SUNFISH"
        return
    end

    local atBeginning =
        (
            match.round == nil
            or tonumber(match.round) == nil
            or tonumber(match.round) <= 1
        )

    if atBeginning then
        local ok, position =
            pcall(
                Sunfish.createPosition,
                Sunfish.initial
            )

        if ok
            and type(position) == "table" then

            Shadow.position = position
            Shadow.ready = true
            Shadow.reason =
                "SYNCED FROM START"

            Shadow.lastSyncMethod =
                "INITIAL"

            return
        end
    end

    -- v4.8: Injecting midgame is supported by replaying the Board module's
    -- FEN history through Sunfish's own legal move generator.
    local ok =
        AttemptShadowResync(
            match,
            "MIDGAME INIT"
        )

    if not ok then
        Shadow.reason =
            Shadow.reason
            or "MIDGAME RESYNC FAILED"
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

local function AdvanceShadowAfterOwnMove(
    match,
    sunfishMove,
    fromPos,
    toMove,
    expectedPosition
)
    if type(match) ~= "table"
        or match.mode == "sunfish" then

        return true
    end

    if Shadow.matchId ~= match.id then
        ResetShadow(match)
    end

    if not Shadow.ready
        or type(Shadow.position) ~= "table" then

        return false,
            Shadow.reason
            or "SHADOW NOT READY"
    end

    -- The move was searched from this exact shadow position.
    -- If something else advanced it in the meantime, do not double-apply.
    if expectedPosition
        and Shadow.position ~= expectedPosition then

        ScheduleShadowResync(
            match,
            "LOCAL COMMIT POSITION CHANGED"
        )

        return false,
            "SHADOW CHANGED • RESYNCING"
    end

    local ok, nextPosition =
        pcall(function()
            return Shadow.position:move(
                sunfishMove
            )
        end)

    if not ok
        or type(nextPosition) ~= "table" then

        Shadow.ready = false
        Shadow.reason =
            "DESYNC: LOCAL SHADOW UPDATE FAILED"

        ScheduleShadowResync(
            match,
            "LOCAL SHADOW UPDATE"
        )

        return false,
            Shadow.reason
    end

    Shadow.position =
        nextPosition

    -- Some servers may echo the sender's move, some may not.
    -- If an echo arrives, ApplyConfirmedMoveToShadow() will ignore
    -- this exact move once rather than advancing the position twice.
    Shadow.pendingKey =
        MoveKey(
            fromPos,
            toMove
        )

    Shadow.pendingUntil =
        os.clock() + 3.0

    Shadow.reason =
        "SYNCED AFTER LOCAL MOVE"

    return true
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

    local positionBefore =
        Shadow.position

    local move =
        MatchMoveToSunfish(
            positionBefore,
            fromPos,
            toMove
        )

    if not move then
        Shadow.ready = false
        Shadow.reason =
            "DESYNC: MOVE CONVERSION FAILED (REMOTE MOVE)"

        local live =
            GetCurrentMatch()

        if live
            and live.id == Shadow.matchId then

            ScheduleShadowResync(
                live,
                "REMOTE MOVE CONVERSION"
            )
        end

        return
    end

    local liveMatch =
        GetCurrentMatch()

    if liveMatch then
        local localTeam =
            GetLocalTeam(
                liveMatch
            )

        if type(localTeam)
            == "boolean" then

            if positionBefore.player
                == localTeam then

                LearningRecordOwnMove(
                    liveMatch,
                    positionBefore,
                    move,
                    nil,
                    "MANUAL"
                )
            else
                LearningRecordTeacherMove(
                    liveMatch,
                    positionBefore,
                    move
                )
            end
        end
    end

    local ok, nextPos =
        pcall(function()
            return positionBefore:move(move)
        end)

    if not ok
        or type(nextPos) ~= "table" then

        Shadow.ready = false
        Shadow.reason =
            "DESYNC: POSITION UPDATE FAILED"

        local live =
            GetCurrentMatch()

        if live
            and live.id == Shadow.matchId then

            ScheduleShadowResync(
                live,
                "REMOTE POSITION UPDATE"
            )
        end

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

SetThinkingNarrative = function()
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
        kingZonePressure = 0,
        kingMobility = 0,
        forcingPressure = 0,
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

                local letter =
                    PieceLetterFromObject(
                        piece.object
                    )

                if letter == "K" then
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

                            if letter == "K" then
                                metrics.kingMobility += 1
                            end

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

    if kingPosition
        and type(enemyPieces) == "table" then

        for _, piece in pairs(enemyPieces) do
            if type(piece) == "table"
                and type(piece.position) == "table" then

                local okMoves, moves =
                    pcall(function()
                        return piece:getMoves()
                    end)

                if okMoves
                    and type(moves) == "table" then

                    for _, move in pairs(moves) do
                        if type(move) == "table" then
                            local dx =
                                math.abs(
                                    move[1]
                                    - kingPosition[1]
                                )

                            local dy =
                                math.abs(
                                    move[2]
                                    - kingPosition[2]
                                )

                            if move[1] == kingPosition[1]
                                and move[2] == kingPosition[2] then

                                metrics.kingThreat = true
                                metrics.forcingPressure += 3

                            elseif dx <= 1
                                and dy <= 1 then

                                metrics.kingZonePressure += 1
                                metrics.forcingPressure += 1
                            end

                            if dx <= 2
                                and dy <= 2 then

                                local target

                                pcall(function()
                                    target =
                                        match:getPiece({
                                            move[1],
                                            move[2],
                                        })
                                end)

                                if type(target) == "table"
                                    and target.team == team then

                                    metrics.forcingPressure += 1
                                end
                            end
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


--// ============================================================
--// AUTOMATIC v4.7: TACTICAL / MATE SAFETY AUDIT
--// ============================================================

local function FinalSearchScore(results)
    if type(results) ~= "table"
        or #results == 0 then
        return nil
    end

    local final = results[#results]

    if type(final) ~= "table" then
        return nil
    end

    return tonumber(final.score1)
end

local function BuildSafetySettings(deep)
    local settings =
        DeepCopy(
            Profiles.Nightmare
            or Profiles.Hard
        )

    settings.worseMoveChance = 0

    if deep then
        settings.nodes =
            math.max(
                tonumber(settings.nodes) or 0,
                Config.AutomaticDeepSafetyNodes
            )

        settings.depth =
            math.max(
                tonumber(settings.depth) or 0,
                12
            )
    else
        settings.nodes =
            math.max(
                20000,
                math.min(
                    tonumber(settings.nodes)
                    or Config.AutomaticSafetyProbeNodes,
                    Config.AutomaticSafetyProbeNodes
                )
            )

        settings.depth =
            math.max(
                6,
                math.min(
                    tonumber(settings.depth) or 6,
                    10
                )
            )
    end

    return settings
end

local function ProbeOpponentAfterMove(
    position,
    ourMove,
    deep
)
    if type(position) ~= "table"
        or type(ourMove) ~= "table" then

        return nil, "INVALID SAFETY INPUT"
    end

    local okNext, nextPosition =
        pcall(function()
            return position:move(
                ourMove
            )
        end)

    if not okNext
        or type(nextPosition) ~= "table" then

        return nil,
            "SAFETY POSITION FAILED"
    end

    local settings =
        BuildSafetySettings(deep)

    local okSearch,
        results,
        mateState =
        pcall(
            Sunfish.search,
            nextPosition,
            settings.nodes,
            settings.depth,
            settings
        )

    if not okSearch then
        return nil,
            "SAFETY SEARCH ERROR: "
            .. tostring(results)
    end

    if type(results) ~= "table"
        or #results == 0 then

        return nil,
            "SAFETY NO RESULT"
    end

    local okChoose,
        enemyMove,
        enemyScore =
        pcall(
            Sunfish.chooseMove,
            results,
            settings
        )

    if not okChoose then
        enemyMove = nil
        enemyScore =
            FinalSearchScore(results)
    end

    enemyScore =
        tonumber(enemyScore)
        or FinalSearchScore(results)
        or 0

    local teacher =
        LearningBestTeacherReply(
            nextPosition
        )

    local teacherUsed = false

    if teacher
        and teacher.entry
        and (tonumber(
            teacher.entry.losses
        ) or 0) >= 1
        and (tonumber(
            teacher.entry.punish
        ) or 0) >= 0.45 then

        enemyMove =
            teacher.move

        teacherUsed = true

        enemyScore =
            math.max(
                enemyScore,
                260
                    + (
                        tonumber(
                            teacher.entry.punish
                        )
                        or 0
                    )
                        * 220
            )
    end

    local mateDanger =
        (
            type(mateState) == "number"
            and mateState > 0
        )
        or enemyScore >= 29000

    local severeDanger =
        mateDanger
        or enemyScore >= 1200

    return {
        nextPosition = nextPosition,
        enemyMove = enemyMove,
        enemyScore = enemyScore,
        mateState = mateState,
        mateDanger = mateDanger,
        severeDanger = severeDanger,
        candidateGap =
            CandidateGap(results),
        settings = settings,
        results = results,

        teacherUsed =
            teacherUsed,

        teacher =
            teacher,
    }
end

local function AddUniqueSafetyCandidate(
    list,
    seen,
    move,
    ownScore,
    source
)
    if type(move) ~= "table" then
        return
    end

    local key =
        MoveIdentity(move)

    if seen[key] then
        return
    end

    seen[key] = true

    list[#list + 1] = {
        move = move,
        ownScore = tonumber(ownScore),
        source = source,
    }
end

local function PrincipalSafetyCandidates(
    primaryMove,
    primaryInfo,
    nightmareMove,
    nightmareInfo
)
    local list = {}
    local seen = {}

    AddUniqueSafetyCandidate(
        list,
        seen,
        primaryMove,
        primaryInfo
            and primaryInfo.score,
        "selected"
    )

    AddUniqueSafetyCandidate(
        list,
        seen,
        nightmareMove,
        nightmareInfo
            and nightmareInfo.score,
        "nightmare"
    )

    local sourceInfo =
        nightmareInfo
        or primaryInfo

    if sourceInfo
        and type(sourceInfo.candidates)
            == "table" then

        for _, candidate in ipairs(
            sourceInfo.candidates
        ) do
            AddUniqueSafetyCandidate(
                list,
                seen,
                candidate.move,
                candidate.score,
                "candidate"
            )

            if #list
                >= Config.AutomaticSafetyCandidates then
                break
            end
        end
    end

    return list
end

local function ShortlistGameLegalDefenses(
    match,
    position,
    team
)
    local pieces =
        team
        and match.whitePieces
        or match.blackPieces

    if type(pieces) ~= "table" then
        return {}
    end

    local moves = {}
    local seen = {}

    for _, piece in pairs(pieces) do
        if type(piece) == "table"
            and piece.team == team
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
                            local key =
                                MoveIdentity(
                                    sunfishMove
                                )

                            if not seen[key] then
                                seen[key] = true

                                local okEval,
                                    eval =
                                    pcall(
                                        Sunfish.evaluateMove,
                                        position,
                                        sunfishMove
                                    )

                                moves[#moves + 1] = {
                                    move = sunfishMove,
                                    ownScore =
                                        okEval
                                        and tonumber(eval)
                                        or -90000,
                                    source = "legal-defense",
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(
        moves,
        function(a, b)
            return (
                tonumber(a.ownScore)
                or -90000
            ) > (
                tonumber(b.ownScore)
                or -90000
            )
        end
    )

    local shortlist = {}

    for i = 1,
        math.min(
            #moves,
            Config.AutomaticDefenseShortlist
        ) do

        shortlist[#shortlist + 1] =
            moves[i]
    end

    return shortlist
end

local function ChooseSafestAuditedCandidate(
    audits
)
    if type(audits) ~= "table"
        or #audits == 0 then
        return nil
    end

    table.sort(
        audits,
        function(a, b)
            if a.audit.mateDanger
                ~= b.audit.mateDanger then

                return not a.audit.mateDanger
            end

            if a.audit.enemyScore
                ~= b.audit.enemyScore then

                return a.audit.enemyScore
                    < b.audit.enemyScore
            end

            return (
                tonumber(a.entry.ownScore)
                or -90000
            ) > (
                tonumber(b.entry.ownScore)
                or -90000
            )
        end
    )

    return audits[1]
end

local function SafetyAuditAutomaticMove(
    match,
    position,
    team,
    primaryMove,
    primaryInfo,
    nightmareMove,
    nightmareInfo,
    forceDeep
)
    if not Config.AutomaticSafetyAudit then
        return primaryMove,
            primaryInfo,
            {
                audited = false,
            }
    end

    SetThinkingNarrative(
        forceDeep
            and "Mate Safety sâu: đang mô phỏng nước đã chọn và cho đối thủ phản công..."
            or "Safety Probe: đang kiểm tra nước này có mở đòn phản công cưỡng bức không...",
        "thinking"
    )

    local firstAudit,
        firstError =
        ProbeOpponentAfterMove(
            position,
            primaryMove,
            forceDeep
        )

    if not firstAudit then
        return primaryMove,
            primaryInfo,
            {
                audited = false,
                error = firstError,
            }
    end

    if not forceDeep
        and not firstAudit.mateDanger
        and not firstAudit.severeDanger then

        return primaryMove,
            primaryInfo,
            {
                audited = true,
                changed = false,
                audit = firstAudit,
            }
    end

    local candidates =
        PrincipalSafetyCandidates(
            primaryMove,
            primaryInfo,
            nightmareMove,
            nightmareInfo
        )

    local audited = {}

    for index, entry in ipairs(candidates) do
        SetThinkingNarrative(
            string.format(
                "Mate Safety %d/%d: kiểm tra phản đòn của đối thủ...",
                index,
                #candidates
            ),
            "thinking"
        )

        local audit

        if forceDeep
            and MoveIdentity(entry.move)
                == MoveIdentity(primaryMove) then

            audit = firstAudit
        else
            audit =
                ProbeOpponentAfterMove(
                    position,
                    entry.move,
                    true
                )
        end

        if type(audit) == "table" then
            audited[#audited + 1] = {
                entry = entry,
                audit = audit,
            }
        end
    end

    local safest =
        ChooseSafestAuditedCandidate(
            audited
        )

    if safest
        and safest.audit.mateDanger then

        SetThinkingNarrative(
            "Candidate chính đều có nguy cơ mate. Quét legal moves để tìm phòng thủ.",
            "warning"
        )

        local defenses =
            ShortlistGameLegalDefenses(
                match,
                position,
                team
            )

        for index, entry in ipairs(defenses) do
            SetThinkingNarrative(
                string.format(
                    "Defense audit %d/%d: thử nước phòng thủ hợp lệ...",
                    index,
                    #defenses
                ),
                "thinking"
            )

            local audit =
                ProbeOpponentAfterMove(
                    position,
                    entry.move,
                    true
                )

            if type(audit) == "table" then
                audited[#audited + 1] = {
                    entry = entry,
                    audit = audit,
                }
            end
        end

        safest =
            ChooseSafestAuditedCandidate(
                audited
            )
    end

    if not safest then
        return primaryMove,
            primaryInfo,
            {
                audited = true,
                changed = false,
                audit = firstAudit,
            }
    end

    local changed =
        MoveIdentity(
            safest.entry.move
        ) ~= MoveIdentity(
            primaryMove
        )

    local selectedInfo =
        primaryInfo

    if nightmareMove
        and nightmareInfo
        and MoveIdentity(
            safest.entry.move
        ) == MoveIdentity(
            nightmareMove
        ) then

        selectedInfo =
            nightmareInfo
    end

    if changed then
        SetThinkingNarrative(
            safest.audit.mateDanger
                and "Không có candidate thoát hoàn toàn; chọn nước phòng thủ kéo dài tốt nhất."
                or string.format(
                    "Safety VETO: bác nước ban đầu. Eval phản công đối thủ còn %+0.2f.",
                    safest.audit.enemyScore / 100
                ),
            safest.audit.mateDanger
                and "warning"
                or "decision"
        )
    end

    return safest.entry.move,
        selectedInfo,
        {
            audited = true,
            changed = changed,
            audit = safest.audit,
            originalAudit = firstAudit,
            source = safest.entry.source,
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
            "Đọc thế: %d legal • %d capture • King mobility %d • pressure %d%s.",
            metrics.legal,
            metrics.captures,
            metrics.kingMobility,
            metrics.kingZonePressure,
            metrics.kingThreat
                and " • CHECK"
                or ""
        ),
        "thinking"
    )

    task.wait()

    SetThinkingNarrative(
        "Easy scout đang đo độ rõ của position...",
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
        easyInfo.candidateGap
        or 99999

    local complexity = 0

    if metrics.kingThreat then
        complexity += 5
    end

    if metrics.kingZonePressure >= 6 then
        complexity += 3
    elseif metrics.kingZonePressure >= 3 then
        complexity += 2
    elseif metrics.kingZonePressure >= 1 then
        complexity += 1
    end

    if metrics.kingMobility <= 1 then
        complexity += 3
    elseif metrics.kingMobility <= 2 then
        complexity += 2
    elseif metrics.kingMobility <= 3 then
        complexity += 1
    end

    if metrics.forcingPressure >= 8 then
        complexity += 3
    elseif metrics.forcingPressure >= 4 then
        complexity += 2
    elseif metrics.forcingPressure >= 1 then
        complexity += 1
    end

    if metrics.legal >= 24 then
        complexity += 2
    elseif metrics.legal >= 16 then
        complexity += 1
    end

    if metrics.tactical >= 5 then
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
        tonumber(easyInfo.score)
        or 0

    if math.abs(easyScore) < 90 then
        complexity += 1
    end

    if not metrics.kingThreat
        and metrics.kingZonePressure == 0
        and metrics.forcingPressure == 0
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

    local critical =
        metrics.kingThreat
        or metrics.kingZonePressure >= 3
        or metrics.kingMobility <= 2
        or metrics.forcingPressure >= 5
        or complexity >= 7

    local chosenMove = easyMove
    local chosenInfo = easyInfo

    local hardMove
    local hardInfo
    local nightmareMove
    local nightmareInfo

    local committeeText = "Easy"

    if complexity <= 2
        and not critical then

        SetThinkingNarrative(
            string.format(
                "Position rõ (gap %.0f). Giữ scout và chạy Safety Probe.",
                gap
            ),
            "thinking"
        )

    elseif complexity <= 4
        and not critical then

        SetThinkingNarrative(
            "Normal đang xác nhận lại scout.",
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
        and not critical then

        SetThinkingNarrative(
            "Thế có chiến thuật. Hard đang kiểm tra principal variation.",
            "thinking"
        )

        hardMove, hardInfo =
            RunSearchProfile(
                position,
                "Hard"
            )

        if hardMove then
            chosenMove = hardMove
            chosenInfo = hardInfo
            committeeText =
                "Easy → Hard"
        end

    else
        SetThinkingNarrative(
            metrics.kingThreat
                and "CHECK / King danger: bỏ majority vote. Hard + Nightmare đang tìm phòng thủ."
                or "Critical position: Nightmare có quyền veto các profile nông.",
            "thinking"
        )

        hardMove, hardInfo =
            RunSearchProfile(
                position,
                "Hard"
            )

        SetThinkingNarrative(
            "Nightmare đang search sâu và giữ quyền veto...",
            "thinking"
        )

        nightmareMove,
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

        local consensus,
            votes =
            ChooseCommitteeResult(
                entries
            )

        committeeText =
            string.format(
                "committee %d/3",
                votes or 1
            )

        if Config.AutomaticNightmareVeto
            and nightmareMove then

            chosenMove = nightmareMove
            chosenInfo = nightmareInfo

            if consensus
                and MoveIdentity(
                    consensus.move
                ) == MoveIdentity(
                    nightmareMove
                ) then

                committeeText =
                    committeeText
                    .. " • Nightmare confirmed"
            else
                committeeText =
                    committeeText
                    .. " • Nightmare VETO"
            end

        elseif consensus then
            chosenMove = consensus.move
            chosenInfo = consensus.info

        elseif nightmareMove then
            chosenMove = nightmareMove
            chosenInfo = nightmareInfo
            committeeText = "Nightmare"
        end
    end

    if Config.NeuralEnabled
        and type(
            Learning.Neural.RerankAutomatic
        ) == "function" then

        chosenMove,
            chosenInfo =
            Learning.Neural.RerankAutomatic(
                match,
                position,
                localTeam,
                chosenMove,
                chosenInfo
            )
    end

    local shouldAudit =
        critical
        or complexity >= 4
        or metrics.tactical >= 2
        or metrics.kingZonePressure > 0

    local safety

    if shouldAudit then
        local auditedMove,
            auditedInfo,
            auditInfo =
            SafetyAuditAutomaticMove(
                match,
                position,
                localTeam,
                chosenMove,
                chosenInfo,
                nightmareMove,
                nightmareInfo,
                critical
            )

        if auditedMove then
            chosenMove = auditedMove
        end

        if auditedInfo then
            chosenInfo = auditedInfo
        end

        safety = auditInfo
    end

    chosenInfo.automatic = {
        complexity = complexity,
        legalMoves = metrics.legal,
        captures = metrics.captures,
        tactical = metrics.tactical,
        kingThreat = metrics.kingThreat,
        kingZonePressure =
            metrics.kingZonePressure,
        kingMobility =
            metrics.kingMobility,
        forcingPressure =
            metrics.forcingPressure,
        scoutGap = gap,
        committee = committeeText,
        safetyAudited =
            safety
            and safety.audited
            or false,
        safetyChanged =
            safety
            and safety.changed
            or false,
        opponentAuditScore =
            safety
            and safety.audit
            and safety.audit.enemyScore
            or nil,
        opponentMateDanger =
            safety
            and safety.audit
            and safety.audit.mateDanger
            or false,

        neuralConfidence =
            chosenInfo.neural
            and chosenInfo.neural.confidence
            or 0,

        neuralChanged =
            chosenInfo.neural
            and chosenInfo.neural.changed
            or false,
    }

    local safetyText = ""

    if chosenInfo.automatic.safetyAudited then
        if chosenInfo.automatic.opponentMateDanger then
            safetyText =
                " • mate danger"
        elseif chosenInfo.automatic.safetyChanged then
            safetyText =
                " • Safety VETO đổi nước"
        else
            safetyText =
                " • Safety OK"
        end
    end

    SetThinkingNarrative(
        string.format(
            "Chốt %s • độ khó %d/9 • %s%s.",
            tostring(
                chosenInfo.selectedMode
            ),
            complexity,
            committeeText,
            safetyText
        ),
        chosenInfo.automatic.opponentMateDanger
            and "warning"
            or "decision"
    )

    return chosenMove,
        chosenInfo
end


--// ============================================================
--// COMPETITIVE / ANTI-ENGINE MODE
--//
--// Outer adversarial verification:
--//   1) Deep root search
--//   2) Build executable candidate pool
--//   3) Probe opponent's best response for every candidate
--//   4) Deep-verify the safest finalists
--//   5) Search our recovery after opponent's best response
--//   6) Pick best worst-case line
--//
--// This is not Stockfish. It is a stronger controller around the
--// game's Sunfish and therefore still has a lower ceiling than a
--// modern native Stockfish build.
--// ============================================================


local function NormalizeClockSeconds(value)
    value =
        tonumber(value)

    if not value
        or value < 0 then

        return nil
    end

    if value > 36000 then
        value /= 1000
    end

    return value
end

local function ParseClockReturn(
    value,
    team
)
    if type(value) == "number" then
        return NormalizeClockSeconds(
            value
        )
    end

    if type(value) ~= "table" then
        return nil
    end

    local candidates = {
        value[team],
        value[
            team
            and "white"
            or "black"
        ],
        value[
            team
            and "White"
            or "Black"
        ],
        value[
            team
            and 1
            or 2
        ],
        value.remaining,
        value.time,
    }

    for _, candidate in ipairs(
        candidates
    ) do
        local seconds =
            NormalizeClockSeconds(
                candidate
            )

        if seconds then
            return seconds
        end
    end

    return nil
end

local function GetClockRemainingSeconds(
    match,
    team
)
    if type(match) ~= "table"
        or type(match.chessClock)
            ~= "table" then

        return nil
    end

    local clock =
        match.chessClock

    if type(
        clock.getRemainingTime
    ) ~= "function" then

        return nil
    end

    local ok, value =
        pcall(
            clock.getRemainingTime,
            clock,
            team
        )

    if ok then
        local parsed =
            ParseClockReturn(
                value,
                team
            )

        if parsed then
            return parsed
        end
    end

    ok, value =
        pcall(
            clock.getRemainingTime,
            clock
        )

    if ok then
        return ParseClockReturn(
            value,
            team
        )
    end

    return nil
end

local function CompetitiveBudgetForClock(
    match,
    team
)
    local remaining =
        GetClockRemainingSeconds(
            match,
            team
        )

    local budget = {
        root =
            Config.CompetitiveRootNodes,
        probe =
            Config.CompetitiveProbeNodes,
        deep =
            Config.CompetitiveDeepProbeNodes,
        recovery =
            Config.CompetitiveRecoveryNodes,

        candidates =
            Config.CompetitiveCandidateLimit,
        finalists =
            Config.CompetitiveFinalists,

        targetSeconds =
            Config.CompetitiveThinkTarget,

        remainingSeconds =
            remaining,
    }

    if remaining
        and remaining
            <= Config.CompetitivePanicTimeSeconds then

        budget.root = 5500
        budget.probe = 0
        budget.deep = 0
        budget.recovery = 0
        budget.candidates = 1
        budget.finalists = 0
        budget.targetSeconds = 1.2

    elseif remaining
        and remaining
            <= Config.CompetitiveCriticalTimeSeconds then

        budget.root = 8000
        budget.probe = 2200
        budget.deep = 0
        budget.recovery = 0
        budget.candidates = 2
        budget.finalists = 0
        budget.targetSeconds = 2.0

    elseif remaining
        and remaining
            <= Config.CompetitiveLowTimeSeconds then

        budget.root = 12500
        budget.probe = 3000
        budget.deep = 5000
        budget.recovery = 0
        budget.candidates = 2
        budget.finalists = 1
        budget.targetSeconds = 3.2
    end

    return budget
end

local function CompetitiveDeadlinePassed(
    deadline,
    reserve
)
    return os.clock()
        >= deadline
            - (reserve or 0)
end

local function RunCompetitiveBudget(
    position,
    nodes,
    minDepth,
    label
)
    nodes =
        tonumber(nodes)
        or 0

    if nodes <= 0 then
        return nil, {
            error =
                "COMP SKIPPED ["
                .. tostring(label)
                .. "]",
        }
    end

    local settings =
        DeepCopy(
            Profiles.Competitive
            or Profiles.Nightmare
        )

    settings.nodes =
        math.max(
            tonumber(nodes) or 65536,
            1000
        )

    settings.depth =
        math.max(
            tonumber(settings.depth) or 10,
            tonumber(minDepth)
                or Config.CompetitiveMinDepth
        )

    settings.worseMoveChance = 0

    local searchStart =
        os.clock()

    local okSearch,
        results,
        mateState =
        pcall(
            Sunfish.search,
            position,
            settings.nodes,
            settings.depth,
            settings
        )

    local elapsed =
        os.clock()
        - searchStart

    if not okSearch then
        return nil, {
            error =
                "COMP SEARCH ERROR ["
                .. tostring(label)
                .. "]: "
                .. tostring(results),
        }
    end

    if type(results) ~= "table"
        or #results == 0 then

        return nil, {
            error =
                "COMP NO RESULT ["
                .. tostring(label)
                .. "]",
        }
    end

    local okChoose,
        move,
        score,
        rank =
        pcall(
            Sunfish.chooseMove,
            results,
            settings
        )

    if not okChoose
        or type(move) ~= "table" then

        return nil, {
            error =
                "COMP CHOOSE FAILED ["
                .. tostring(label)
                .. "]",
        }
    end

    return move, {
        results = results,
        candidates =
            CandidateMovesFromSearch(
                results
            ),
        score = tonumber(score)
            or FinalSearchScore(results)
            or 0,
        rank = rank,
        mateState = mateState,
        settings = settings,
        selectedMode = "Competitive",
        candidateGap =
            CandidateGap(results),

        elapsed =
            elapsed,
    }
end

local function CompetitiveOpponentProbe(
    position,
    ourMove,
    nodes,
    label
)
    local okNext,
        nextPosition =
        pcall(function()
            return position:move(
                ourMove
            )
        end)

    if not okNext
        or type(nextPosition) ~= "table" then

        return nil,
            "COMP POSITION FAILED"
    end

    local enemyMove,
        enemyInfo =
        RunCompetitiveBudget(
            nextPosition,
            nodes,
            Config.CompetitiveMinDepth,
            label
        )

    if not enemyMove
        or not enemyInfo then

        return nil,
            enemyInfo
                and enemyInfo.error
                or "COMP ENEMY SEARCH FAILED"
    end

    local enemyScore =
        tonumber(enemyInfo.score)
        or 0

    local teacher =
        LearningBestTeacherReply(
            nextPosition
        )

    local teacherUsed = false

    if teacher
        and teacher.entry then

        local punish =
            tonumber(
                teacher.entry.punish
            )
            or 0

        local learnedLosses =
            tonumber(
                teacher.entry.losses
            )
            or 0

        if learnedLosses >= 1
            and punish >= 0.45 then

            enemyMove =
                teacher.move

            teacherUsed = true

            enemyScore =
                math.max(
                    enemyScore,
                    260
                        + punish
                            * 220
                )
        end
    end

    local mateDanger =
        (
            type(enemyInfo.mateState)
                == "number"
            and enemyInfo.mateState > 0
        )
        or enemyScore >= 29000

    return {
        nextPosition = nextPosition,
        enemyMove = enemyMove,
        enemyInfo = enemyInfo,
        enemyScore = enemyScore,
        mateDanger = mateDanger,
        severeDanger =
            mateDanger
            or enemyScore >= 1200,

        teacherUsed =
            teacherUsed,

        teacher =
            teacher,
    }
end

local function AddCompetitiveCandidate(
    pool,
    seen,
    match,
    position,
    team,
    move,
    ownScore,
    source
)
    if type(move) ~= "table" then
        return
    end

    local key =
        MoveIdentity(move)

    if seen[key] then
        return
    end

    -- Competitive only spends expensive search budget on moves that
    -- the game's own piece:getMoves() accepts.
    local resolved =
        ResolveGameMove(
            match,
            move,
            position,
            team
        )

    if not resolved then
        return
    end

    seen[key] = true

    local memoryBias =
        LearningOwnMoveBias(
            position,
            move
        )

    local repetitionRisk =
        type(
            Learning.RepetitionRisk
        ) == "function"
        and Learning.RepetitionRisk(
            position,
            move
        )
        or 0

    local neuralBias = 0
    local neuralValue = 0
    local neuralConfidence = 0

    if Config.NeuralEnabled
        and type(
            Learning.Neural.MoveBias
        ) == "function" then

        neuralBias,
            neuralValue,
            neuralConfidence =
            Learning.Neural.MoveBias(
                position,
                move,
                team
            )
    end

    local repetitionPenalty = 0

    if repetitionRisk >= 2
        and (
            tonumber(ownScore)
            or 0
        ) > -Config.LearningRepetitionAvoidEval then

        repetitionPenalty =
            Config.LearningRepetitionHardPenalty
    end

    pool[#pool + 1] = {
        move = move,

        ownScore =
            (
                tonumber(ownScore)
                or -90000
            )
            + memoryBias
            + neuralBias
            - repetitionPenalty,

        repetitionRisk =
            repetitionRisk,

        neuralBias =
            neuralBias,

        neuralValue =
            neuralValue,

        neuralConfidence =
            neuralConfidence,

        rawScore =
            tonumber(ownScore)
            or -90000,

        memoryBias =
            memoryBias,

        source = source,
        resolved = resolved,
    }
end

local function BuildCompetitiveCandidatePool(
    match,
    position,
    team,
    rootMove,
    rootInfo
)
    local pool = {}
    local seen = {}

    AddCompetitiveCandidate(
        pool,
        seen,
        match,
        position,
        team,
        rootMove,
        rootInfo
            and rootInfo.score,
        "root"
    )

    if rootInfo
        and type(rootInfo.candidates)
            == "table" then

        for _, candidate in ipairs(
            rootInfo.candidates
        ) do
            AddCompetitiveCandidate(
                pool,
                seen,
                match,
                position,
                team,
                candidate.move,
                candidate.score,
                "root-candidate"
            )

            if #pool
                >= Config.CompetitiveCandidateLimit then

                break
            end
        end
    end

    -- Fill missing slots using game-legal moves, ranked by the game's
    -- Sunfish static move evaluation.
    if #pool
        < Config.CompetitiveCandidateLimit then

        local legal =
            ShortlistGameLegalDefenses(
                match,
                position,
                team
            )

        for _, entry in ipairs(legal) do
            AddCompetitiveCandidate(
                pool,
                seen,
                match,
                position,
                team,
                entry.move,
                entry.ownScore,
                "legal"
            )

            if #pool
                >= Config.CompetitiveCandidateLimit then

                break
            end
        end
    end

    return pool
end

local function CompetitiveRecoveryScore(
    opponentAudit,
    nodeBudget
)
    if type(opponentAudit) ~= "table"
        or type(opponentAudit.enemyMove)
            ~= "table"
        or type(opponentAudit.nextPosition)
            ~= "table" then

        return 0,
            nil
    end

    local okPosition,
        ourPosition =
        pcall(function()
            return opponentAudit.nextPosition:move(
                opponentAudit.enemyMove
            )
        end)

    if not okPosition
        or type(ourPosition) ~= "table" then

        return 0,
            nil
    end

    local ourMove,
        ourInfo =
        RunCompetitiveBudget(
            ourPosition,
            tonumber(nodeBudget)
                or Config.CompetitiveRecoveryNodes,
            14,
            "RECOVERY"
        )

    if not ourMove
        or not ourInfo then

        return 0,
            nil
    end

    return tonumber(ourInfo.score)
            or 0,
        ourInfo
end

local function CompetitiveUtility(
    entry,
    audit,
    recoveryScore
)
    if audit.mateDanger then
        return -1000000000
    end

    -- Opponent search is from the opponent's perspective:
    -- lower enemyScore is better for us.
    --
    -- Recovery score is from our perspective after their best reply:
    -- higher is better for us.
    local utility =
        -(
            tonumber(audit.enemyScore)
            or 0
        )

    utility +=
        0.38
        * (
            tonumber(recoveryScore)
            or 0
        )

    -- Small tie-break toward the move that root search liked.
    utility +=
        0.06
        * (
            tonumber(entry.ownScore)
            or 0
        )

    return utility
end

local function CompetitiveSearch(
    match,
    position
)
    local team =
        GetLocalTeam(match)

    if type(team) ~= "boolean" then
        return nil, {
            error =
                "COMPETITIVE: UNKNOWN TEAM",
        }
    end

    local budget =
        CompetitiveBudgetForClock(
            match,
            team
        )

    local startedAt =
        os.clock()

    local deadline =
        startedAt
        + budget.targetSeconds

    local clockText =
        budget.remainingSeconds
        and string.format(
            " • clock %.0fs",
            budget.remainingSeconds
        )
        or ""

    SetThinkingNarrative(
        string.format(
            "Competitive FAST: root %dk%s • target %.1fs.",
            math.floor(
                budget.root / 1000
            ),
            clockText,
            budget.targetSeconds
        ),
        "thinking"
    )

    local rootMove,
        rootInfo =
        RunCompetitiveBudget(
            position,
            budget.root,
            Config.CompetitiveMinDepth,
            "ROOT"
        )

    if not rootMove
        or not rootInfo then

        return nil,
            rootInfo
            or {
                error =
                    "COMPETITIVE ROOT FAILED",
            }
    end

    if budget.candidates <= 1
        or budget.probe <= 0
        or CompetitiveDeadlinePassed(
            deadline,
            0.55
        ) then

        rootInfo.selectedMode =
            "Competitive"

        rootInfo.competitive = {
            fastExit = true,
            elapsed =
                os.clock()
                - startedAt,
            remainingSeconds =
                budget.remainingSeconds,
        }

        rootInfo.skipPrediction = true

        SetThinkingNarrative(
            string.format(
                "Competitive FAST chốt root sau %.1fs để giữ clock.",
                rootInfo.competitive.elapsed
            ),
            "decision"
        )

        return rootMove,
            rootInfo
    end

    local pool =
        BuildCompetitiveCandidatePool(
            match,
            position,
            team,
            rootMove,
            rootInfo
        )

    while #pool
        > budget.candidates do

        table.remove(pool)
    end

    if #pool == 0 then
        rootInfo.skipPrediction = true
        return rootMove, rootInfo
    end

    local fastAudits = {}

    for index, entry in ipairs(pool) do
        if CompetitiveDeadlinePassed(
            deadline,
            0.70
        ) then
            break
        end

        local memoryText = ""

        if math.abs(
            entry.memoryBias
            or 0
        ) >= 1 then

            memoryText =
                string.format(
                    " • memory %+d",
                    math.floor(
                        entry.memoryBias
                    )
                )
        end

        SetThinkingNarrative(
            string.format(
                "Probe %d/%d • %dk%s.",
                index,
                #pool,
                math.floor(
                    budget.probe
                    / 1000
                ),
                memoryText
            ),
            "thinking"
        )

        local audit =
            CompetitiveOpponentProbe(
                position,
                entry.move,
                budget.probe,
                "PROBE "
                    .. tostring(index)
            )

        if type(audit) == "table" then
            if audit.teacherUsed then
                SetThinkingNarrative(
                    "Teacher Memory: phản đòn này từng xuất hiện trong một trận thua; ép nó vào line.",
                    "warning"
                )
            end

            fastAudits[
                #fastAudits + 1
            ] = {
                entry = entry,
                audit = audit,
            }
        end

        task.wait()
    end

    if #fastAudits == 0 then
        rootInfo.competitive = {
            candidateCount = #pool,
            fallback = true,
            elapsed =
                os.clock()
                - startedAt,
        }

        rootInfo.skipPrediction = true

        return rootMove,
            rootInfo
    end

    table.sort(
        fastAudits,
        function(a, b)
            if a.audit.mateDanger
                ~= b.audit.mateDanger then

                return not a.audit.mateDanger
            end

            if a.audit.enemyScore
                ~= b.audit.enemyScore then

                return a.audit.enemyScore
                    < b.audit.enemyScore
            end

            return a.entry.ownScore
                > b.entry.ownScore
        end
    )

    local winner =
        fastAudits[1]

    if budget.finalists > 0
        and budget.deep > 0
        and not CompetitiveDeadlinePassed(
            deadline,
            1.05
        ) then

        SetThinkingNarrative(
            string.format(
                "Deep finalist • %dk.",
                math.floor(
                    budget.deep / 1000
                )
            ),
            "thinking"
        )

        local deepAudit =
            CompetitiveOpponentProbe(
                position,
                winner.entry.move,
                budget.deep,
                "FINAL"
            )

        if type(deepAudit) == "table" then
            winner.audit =
                deepAudit
        end
    end

    local recoveryScore = 0
    local recoveryInfo

    if budget.recovery > 0
        and not CompetitiveDeadlinePassed(
            deadline,
            0.70
        ) then

        recoveryScore,
            recoveryInfo =
            CompetitiveRecoveryScore(
                winner.audit,
                budget.recovery
            )
    end

    winner.recoveryScore =
        recoveryScore

    winner.recoveryInfo =
        recoveryInfo

    winner.utility =
        CompetitiveUtility(
            winner.entry,
            winner.audit,
            recoveryScore
        )

    local selectedMove =
        winner.entry.move

    local selectedInfo =
        rootInfo

    selectedInfo.selectedMode =
        "Competitive"

    selectedInfo.score =
        -(
            tonumber(
                winner.audit.enemyScore
            )
            or 0
        )

    selectedInfo.mateState = nil

    selectedInfo.competitive = {
        candidateCount = #pool,
        probedCount =
            #fastAudits,

        enemyScore =
            winner.audit.enemyScore,

        recoveryScore =
            recoveryScore,

        utility =
            winner.utility,

        mateDanger =
            winner.audit.mateDanger,

        teacherUsed =
            winner.audit.teacherUsed
            or false,

        memoryBias =
            winner.entry.memoryBias
            or 0,

        neuralBias =
            winner.entry.neuralBias
            or 0,

        neuralValue =
            winner.entry.neuralValue
            or 0,

        neuralConfidence =
            winner.entry.neuralConfidence
            or 0,

        source =
            winner.entry.source,

        elapsed =
            os.clock()
            - startedAt,

        remainingSeconds =
            budget.remainingSeconds,
    }

    selectedInfo.precomputedPrediction = {
        move =
            winner.audit.enemyMove,

        position =
            winner.audit.nextPosition,

        score =
            winner.audit.enemyScore,

        results =
            winner.audit.enemyInfo
            and winner.audit.enemyInfo.results,

        mateState =
            winner.audit.enemyInfo
            and winner.audit.enemyInfo.mateState,

        confidence =
            winner.audit.enemyInfo
            and PredictionConfidence(
                winner.audit.enemyInfo.results
            )
            or 0,
    }

    if winner.audit.mateDanger then
        SetThinkingNarrative(
            string.format(
                "Competitive FAST: mate danger • chốt line tốt nhất sau %.1fs.",
                selectedInfo.competitive.elapsed
            ),
            "warning"
        )
    else
        SetThinkingNarrative(
            string.format(
                "Competitive FAST %.1fs • enemy %+0.2f%s.",
                selectedInfo.competitive.elapsed,
                winner.audit.enemyScore
                    / 100,
                winner.audit.teacherUsed
                    and " • TEACHER"
                    or ""
            ),
            "decision"
        )
    end

    return selectedMove,
        selectedInfo
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

    elseif Config.Mode == "Competitive" then
        bestMove, info =
            CompetitiveSearch(
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

    if Config.Mode ~= "Automatic"
        and Config.Mode ~= "Competitive" then

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

    if bestMove
        and type(
            Learning.ApplyRepetitionGuard
        ) == "function" then

        bestMove, info =
            Learning.ApplyRepetitionGuard(
                match,
                position,
                bestMove,
                info
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
    if Config.Mode == "Competitive" then
        -- Search itself is already expensive; do not add fake human delay.
        return 0.20,
            false
    end

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

        if automatic.safetyChanged then
            delay +=
                RandomRange(
                    0.35,
                    1.15
                )
        end

        if automatic.opponentMateDanger then
            delay +=
                RandomRange(
                    0.50,
                    1.30
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

local function NewHUDFrame(
    name,
    size,
    position,
    anchorPoint
)
    local frame =
        Instance.new("Frame")

    frame.Name = name
    frame.Size = size
    frame.Position = position

    frame.AnchorPoint =
        anchorPoint or Vector2.new(0, 0)

    frame.BackgroundColor3 =
        Color3.fromRGB(17, 19, 24)

    frame.BackgroundTransparency = 0.12
    frame.BorderSizePixel = 0

    -- Needed for touch/mouse dragging.
    frame.Active = true
    frame.ZIndex = 6
    frame.Parent = HUDRoot

    Instance.new(
        "UICorner",
        frame
    ).CornerRadius =
        UDim.new(0, 8)

    local stroke =
        Instance.new("UIStroke")

    stroke.Color =
        Color3.fromRGB(54, 58, 69)

    stroke.Transparency = 0.35
    stroke.Thickness = 1
    stroke.Parent = frame

    return frame
end

-- Generic touch + mouse dragging for every HUD element.
local function MakeHUDDraggable(frame)
    local dragging = false
    local dragInput
    local dragStart
    local startPosition

    local function update(input)
        if not dragging
            or not dragStart
            or not startPosition then

            return
        end

        local delta =
            input.Position - dragStart

        frame.Position =
            UDim2.new(
                startPosition.X.Scale,
                startPosition.X.Offset + delta.X,
                startPosition.Y.Scale,
                startPosition.Y.Offset + delta.Y
            )
    end

    frame.InputBegan:Connect(
        function(input)
            if input.UserInputType
                    == Enum.UserInputType.MouseButton1
                or input.UserInputType
                    == Enum.UserInputType.Touch then

                dragging = true
                dragStart = input.Position
                startPosition = frame.Position

                input.Changed:Connect(
                    function()
                        if input.UserInputState
                            == Enum.UserInputState.End then

                            dragging = false
                        end
                    end
                )
            end
        end
    )

    frame.InputChanged:Connect(
        function(input)
            if input.UserInputType
                    == Enum.UserInputType.MouseMovement
                or input.UserInputType
                    == Enum.UserInputType.Touch then

                dragInput = input
            end
        end
    )

    UserInputService.InputChanged:Connect(
        function(input)
            if dragging
                and (
                    input == dragInput
                    or input.UserInputType
                        == Enum.UserInputType.Touch
                ) then

                update(input)
            end
        end
    )
end

--// ------------------------------------------------------------
--// PIECE HUD
--// One compact card:
--//    YOU
--//    ENEMY
--//
--// Piece graphics are ViewportFrames rendering cloned chess models
--// from currentMatch itself. No Unicode chess font is required.
--// ------------------------------------------------------------

local PieceStackHUD =
    NewHUDFrame(
        "PieceStackHUD",
        UDim2.fromOffset(218, 104),
        UDim2.new(0, 12, 0, 134),
        Vector2.new(0, 0)
    )

local Divider =
    Instance.new("Frame")

Divider.Position =
    UDim2.new(0, 8, 0.5, 0)

Divider.Size =
    UDim2.new(1, -16, 0, 1)

Divider.BackgroundColor3 =
    Color3.fromRGB(66, 69, 80)

Divider.BackgroundTransparency = 0.35
Divider.BorderSizePixel = 0
Divider.ZIndex = 7
Divider.Parent = PieceStackHUD

local function NewPieceRow(
    parent,
    y,
    titleText,
    titleAlign
)
    local row =
        Instance.new("Frame")

    row.Position =
        UDim2.fromOffset(0, y)

    row.Size =
        UDim2.new(1, 0, 0, 51)

    row.BackgroundTransparency = 1
    row.ZIndex = 7
    row.Parent = parent

    local title =
        Instance.new("TextLabel")

    title.Position =
        UDim2.fromOffset(8, 4)

    title.Size =
        UDim2.fromOffset(54, 14)

    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.Text = titleText
    title.TextSize = 8

    title.TextColor3 =
        Color3.fromRGB(210, 214, 225)

    title.TextXAlignment =
        titleAlign
        or Enum.TextXAlignment.Left

    title.ZIndex = 8
    title.Parent = row

    local cells = {}
    local order = {"Q", "R", "B", "N", "P"}

    for index, letter in ipairs(order) do
        local cell =
            Instance.new("Frame")

        cell.Position =
            UDim2.fromOffset(
                57 + (index - 1) * 30,
                3
            )

        cell.Size =
            UDim2.fromOffset(29, 45)

        cell.BackgroundTransparency = 1
        cell.ZIndex = 8
        cell.Parent = row

        local viewport =
            Instance.new("ViewportFrame")

        viewport.Name =
            "Icon_" .. letter

        viewport.Position =
            UDim2.fromOffset(2, 0)

        viewport.Size =
            UDim2.fromOffset(25, 29)

        viewport.BackgroundTransparency = 1
        viewport.BorderSizePixel = 0

        viewport.Ambient =
            Color3.fromRGB(190, 190, 200)

        viewport.LightColor =
            Color3.fromRGB(255, 255, 255)

        viewport.LightDirection =
            Vector3.new(-1, -1, -1)

        viewport.ZIndex = 8
        viewport.Parent = cell

        -- Only shown if cloning/rendering a game model is unavailable.
        -- Uses simple ASCII letters, never unsupported  glyphs.
        local fallback =
            Instance.new("TextLabel")

        fallback.Size =
            UDim2.fromScale(1, 1)

        fallback.BackgroundTransparency = 1
        fallback.Font = Enum.Font.GothamBold
        fallback.Text = letter
        fallback.TextSize = 13

        fallback.TextColor3 =
            Color3.fromRGB(205, 209, 220)

        fallback.Visible = true
        fallback.ZIndex = 9
        fallback.Parent = viewport

        local count =
            Instance.new("TextLabel")

        count.Position =
            UDim2.fromOffset(0, 29)

        count.Size =
            UDim2.fromOffset(29, 13)

        count.BackgroundTransparency = 1
        count.Font = Enum.Font.GothamMedium
        count.Text = "0"
        count.TextSize = 8

        count.TextColor3 =
            Color3.fromRGB(195, 199, 211)

        count.TextXAlignment =
            Enum.TextXAlignment.Center

        count.ZIndex = 8
        count.Parent = cell

        cells[letter] = {
            viewport = viewport,
            fallback = fallback,
            count = count,
        }
    end

    return row, title, cells
end

local YouHUD,
    YouTitle,
    YouPieceCells =
    NewPieceRow(
        PieceStackHUD,
        0,
        "YOU",
        Enum.TextXAlignment.Left
    )

local EnemyHUD,
    EnemyTitle,
    EnemyPieceCells =
    NewPieceRow(
        PieceStackHUD,
        52,
        "ENEMY",
        Enum.TextXAlignment.Left
    )

local PieceIconSourceCache = {}

local function ClearViewport(viewport)
    for _, child in ipairs(
        viewport:GetChildren()
    ) do
        if child:IsA("Camera")
            or child:IsA("WorldModel") then

            child:Destroy()
        end
    end
end

local function RenderGamePieceIcon(
    cell,
    sourceObject
)
    if not cell
        or not cell.viewport then

        return
    end

    local viewport = cell.viewport

    -- If that exact source is already rendered, do nothing.
    if sourceObject
        and PieceIconSourceCache[viewport]
            == sourceObject
        and viewport:FindFirstChildOfClass(
            "WorldModel"
        ) then

        cell.fallback.Visible = false
        return
    end

    if typeof(sourceObject) ~= "Instance" then
        -- Keep an existing rendered model even if this piece type has
        -- just been captured and no current sample remains.
        if viewport:FindFirstChildOfClass(
            "WorldModel"
        ) then

            cell.fallback.Visible = false
            return
        end

        cell.fallback.Visible = true
        return
    end

    local clone

    local okClone =
        pcall(function()
            local oldArchivable =
                sourceObject.Archivable

            sourceObject.Archivable = true
            clone = sourceObject:Clone()
            sourceObject.Archivable =
                oldArchivable
        end)

    if not okClone
        or typeof(clone) ~= "Instance" then

        cell.fallback.Visible = true
        return
    end

    ClearViewport(viewport)

    local world =
        Instance.new("WorldModel")

    world.Parent = viewport

    -- Remove behavior from cloned visual model.
    for _, descendant in ipairs(
        clone:GetDescendants()
    ) do
        if descendant:IsA("Script")
            or descendant:IsA("LocalScript") then

            descendant:Destroy()

        elseif descendant:IsA("BasePart") then
            descendant.Anchored = true
            descendant.CanCollide = false
            descendant.CanTouch = false
            descendant.CanQuery = false
        end
    end

    if clone:IsA("BasePart") then
        clone.Anchored = true
        clone.CanCollide = false
        clone.CanTouch = false
        clone.CanQuery = false
    end

    clone.Parent = world

    local center
    local size

    if clone:IsA("Model") then
        local okBox, boxCF, boxSize =
            pcall(function()
                local cf, s =
                    clone:GetBoundingBox()

                return cf, s
            end)

        if okBox then
            center = boxCF.Position
            size = boxSize
        end

    elseif clone:IsA("BasePart") then
        center = clone.Position
        size = clone.Size
    end

    if not center or not size then
        clone:Destroy()
        world:Destroy()
        cell.fallback.Visible = true
        return
    end

    local maxSize =
        math.max(
            size.X,
            size.Y,
            size.Z,
            0.5
        )

    local camera =
        Instance.new("Camera")

    camera.FieldOfView = 32

    local target =
        center
        + Vector3.new(
            0,
            size.Y * 0.05,
            0
        )

    local distance =
        maxSize * 2.25

    camera.CFrame =
        CFrame.lookAt(
            target
                + Vector3.new(
                    distance * 0.55,
                    distance * 0.28,
                    distance
                ),
            target
        )

    camera.Parent = viewport
    viewport.CurrentCamera = camera

    PieceIconSourceCache[viewport] =
        sourceObject

    cell.fallback.Visible = false
end

local function UpdatePieceRow(
    cells,
    counts,
    samples
)
    local order = {"Q", "R", "B", "N", "P"}

    for _, letter in ipairs(order) do
        local cell = cells[letter]

        if cell then
            cell.count.Text =
                tostring(
                    counts[letter]
                    or 0
                )

            RenderGamePieceIcon(
                cell,
                samples
                    and samples[letter]
                    or nil
            )
        end
    end
end

--// ------------------------------------------------------------
--// EVALUATION HUD
--// ------------------------------------------------------------

local EvalHUD =
    NewHUDFrame(
        "EvaluationHUD",
        UDim2.fromOffset(205, 50),
        UDim2.new(0.5, 0, 0, 76),
        Vector2.new(0.5, 0)
    )

local MaterialLabel =
    Instance.new("TextLabel")

MaterialLabel.Position =
    UDim2.fromOffset(7, 3)

MaterialLabel.Size =
    UDim2.new(1, -14, 0, 13)

MaterialLabel.BackgroundTransparency = 1
MaterialLabel.Font = Enum.Font.GothamMedium
MaterialLabel.Text = "MATERIAL +0"
MaterialLabel.TextSize = 8

MaterialLabel.TextColor3 =
    Color3.fromRGB(171, 177, 194)

MaterialLabel.TextXAlignment =
    Enum.TextXAlignment.Center

MaterialLabel.ZIndex = 7
MaterialLabel.Parent = EvalHUD

local WinLabel =
    Instance.new("TextLabel")

WinLabel.Position =
    UDim2.fromOffset(7, 17)

WinLabel.Size =
    UDim2.new(1, -14, 0, 16)

WinLabel.BackgroundTransparency = 1
WinLabel.Font = Enum.Font.GothamBold
WinLabel.Text = "WIN --%  •  EVAL --"
WinLabel.TextSize = 9

WinLabel.TextColor3 =
    Color3.fromRGB(215, 220, 233)

WinLabel.TextXAlignment =
    Enum.TextXAlignment.Center

WinLabel.ZIndex = 7
WinLabel.Parent = EvalHUD

local WinBar =
    Instance.new("Frame")

WinBar.Position =
    UDim2.fromOffset(10, 38)

WinBar.Size =
    UDim2.new(1, -20, 0, 5)

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

--// ------------------------------------------------------------
--// MOVE / PREDICTION HUD
--// ------------------------------------------------------------

local MoveHUD =
    NewHUDFrame(
        "MovePredictionHUD",
        UDim2.fromOffset(245, 47),
        UDim2.new(0.5, 0, 0, 132),
        Vector2.new(0.5, 0)
    )

local AIMoveLabel =
    Instance.new("TextLabel")

AIMoveLabel.Position =
    UDim2.fromOffset(8, 3)

AIMoveLabel.Size =
    UDim2.new(1, -16, 0, 19)

AIMoveLabel.BackgroundTransparency = 1
AIMoveLabel.Font = Enum.Font.GothamMedium
AIMoveLabel.Text = "AI • --"
AIMoveLabel.TextSize = 9

AIMoveLabel.TextColor3 =
    Color3.fromRGB(126, 190, 245)

AIMoveLabel.TextXAlignment =
    Enum.TextXAlignment.Left

AIMoveLabel.ZIndex = 7
AIMoveLabel.Parent = MoveHUD

local EnemyMoveLabel =
    Instance.new("TextLabel")

EnemyMoveLabel.Position =
    UDim2.fromOffset(8, 23)

EnemyMoveLabel.Size =
    UDim2.new(1, -16, 0, 19)

EnemyMoveLabel.BackgroundTransparency = 1
EnemyMoveLabel.Font = Enum.Font.GothamMedium
EnemyMoveLabel.Text = "ENEMY • --"
EnemyMoveLabel.TextSize = 9

EnemyMoveLabel.TextColor3 =
    Color3.fromRGB(235, 135, 125)

EnemyMoveLabel.TextXAlignment =
    Enum.TextXAlignment.Left

EnemyMoveLabel.ZIndex = 7
EnemyMoveLabel.Parent = MoveHUD

--// ------------------------------------------------------------
--// THINKING HUD
--// ------------------------------------------------------------

local ThinkingCard =
    NewHUDFrame(
        "ThinkingHUD",
        UDim2.fromOffset(315, 66),
        UDim2.new(0.5, 0, 1, -20),
        Vector2.new(0.5, 1)
    )

local ThinkingTitle =
    Instance.new("TextLabel")

ThinkingTitle.Position =
    UDim2.fromOffset(8, 5)

ThinkingTitle.Size =
    UDim2.new(1, -16, 0, 14)

ThinkingTitle.BackgroundTransparency = 1
ThinkingTitle.Font = Enum.Font.GothamBold
ThinkingTitle.Text = "NỘI TÂM • TELEMETRY"
ThinkingTitle.TextSize = 8

ThinkingTitle.TextColor3 =
    Color3.fromRGB(155, 166, 205)

ThinkingTitle.TextXAlignment =
    Enum.TextXAlignment.Left

ThinkingTitle.ZIndex = 7
ThinkingTitle.Parent = ThinkingCard

local ThinkingText =
    Instance.new("TextLabel")

ThinkingText.Position =
    UDim2.fromOffset(8, 21)

ThinkingText.Size =
    UDim2.new(1, -16, 0, 39)

ThinkingText.BackgroundTransparency = 1
ThinkingText.Font = Enum.Font.Gotham

ThinkingText.Text =
    "Chưa phân tích. Automatic sẽ tự chọn độ sâu theo thế cờ."

ThinkingText.TextSize = 8

ThinkingText.TextColor3 =
    Color3.fromRGB(190, 194, 207)

ThinkingText.TextWrapped = true

ThinkingText.TextXAlignment =
    Enum.TextXAlignment.Left

ThinkingText.TextYAlignment =
    Enum.TextYAlignment.Top

ThinkingText.ZIndex = 7
ThinkingText.Parent = ThinkingCard

-- Every HUD is independently draggable.
MakeHUDDraggable(PieceStackHUD)
MakeHUDDraggable(EvalHUD)
MakeHUDDraggable(MoveHUD)
MakeHUDDraggable(ThinkingCard)

local function RefreshHUDVisibility()
    PieceStackHUD.Visible =
        Config.ShowPieceHUD

    EvalHUD.Visible =
        Config.ShowEvalHUD

    MoveHUD.Visible =
        Config.ShowMoveHUD

    ThinkingCard.Visible =
        Config.ShowThinkingHUD
end

local HUDSleeping = false

local function SetHUDSleeping(sleeping)
    if not Config.SleepHUDInLobby then
        sleeping = false
    end

    if HUDSleeping == sleeping then
        return
    end

    HUDSleeping = sleeping

    if sleeping then
        -- Keep the compact settings bar available, but stop rendering
        -- the independent HUD layers (including 10 ViewportFrames).
        PieceStackHUD.Visible = false
        EvalHUD.Visible = false
        MoveHUD.Visible = false
        ThinkingCard.Visible = false
    else
        RefreshHUDVisibility()
    end
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
        "WIN --%  •  EVAL --"

    WinFill.Size =
        UDim2.new(0.5, 0, 1, 0)

    AIMoveLabel.Text = "AI • --"
    EnemyMoveLabel.Text = "ENEMY • --"

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

        local blank =
            EmptyPieceCounts()

        UpdatePieceRow(
            YouPieceCells,
            blank,
            nil
        )

        UpdatePieceRow(
            EnemyPieceCells,
            blank,
            nil
        )

        MaterialLabel.Text =
            "MATERIAL --"

        return
    end

    local enemyTeam =
        not localTeam

    local you,
        youSamples =
        CountTeamPieces(
            match,
            localTeam
        )

    local enemy,
        enemySamples =
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
            238,
            240,
            246
        )
        or Color3.fromRGB(
            171,
            176,
            190
        )

    EnemyTitle.TextColor3 =
        enemyTeam
        and Color3.fromRGB(
            238,
            240,
            246
        )
        or Color3.fromRGB(
            171,
            176,
            190
        )

    UpdatePieceRow(
        YouPieceCells,
        you,
        youSamples
    )

    UpdatePieceRow(
        EnemyPieceCells,
        enemy,
        enemySamples
    )

    local delta =
        MaterialScore(you)
        - MaterialScore(enemy)

    MaterialLabel.Text =
        "MATERIAL "
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
            "WIN %d%%  •  EVAL %+.2f",
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
            or "AI • "
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
                "ENEMY • %s  •  %d%%",
                enemyText,
                prediction.confidence or 0
            )
    elseif Config.EnemyPrediction then
        EnemyMoveLabel.Text =
            "ENEMY • prediction unavailable"
    else
        EnemyMoveLabel.Text =
            "ENEMY • prediction OFF"
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
                "ENEMY • prediction OFF"
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
    "HUD • Config._Runtime.Thinking",
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

SetStatus = function(text, bad)
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

Header.InputBegan:Connect(
    function(input)
        if input.UserInputType
                == Enum.UserInputType.MouseButton1
            or input.UserInputType
                == Enum.UserInputType.Touch then

            Config._Runtime.Dragging = true
            Config._Runtime.DragStart = input.Position
            Config._Runtime.MainStart = Main.Position
        end
    end
)

UserInputService.InputChanged:Connect(
    function(input)
        if not Config._Runtime.Dragging then
            return
        end

        if input.UserInputType
                == Enum.UserInputType.MouseMovement
            or input.UserInputType
                == Enum.UserInputType.Touch then

            local delta =
                input.Position - Config._Runtime.DragStart

            Main.Position =
                UDim2.new(
                    Config._Runtime.MainStart.X.Scale,
                    Config._Runtime.MainStart.X.Offset
                        + delta.X,

                    Config._Runtime.MainStart.Y.Scale,
                    Config._Runtime.MainStart.Y.Offset
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

            Config._Runtime.Dragging = false
        end
    end
)

--// ============================================================
--// ANALYZE / AUTOMOVE
--// ============================================================


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
    if Config._Runtime.Thinking then
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

    Config._Runtime.Thinking = true

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
        Config._Runtime.Thinking = false

        local crashText =
            "SEARCH CRASH: "
            .. tostring(bestMove)

        SetThinkingNarrative(
            crashText,
            "warning"
        )

        SetStatus(
            crashText,
            true
        )

        return false
    end

    if not bestMove then
        Config._Runtime.Thinking = false

        local searchError =
            info
            and info.error
            or "NO MOVE"

        SetThinkingNarrative(
            tostring(searchError),
            "warning"
        )

        SetStatus(
            searchError,
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

        Config._Runtime.Thinking = false

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

        if Config.Mode == "Competitive"
            and info.skipPrediction then

            prediction = nil

        elseif not usedEmergency
            and info.precomputedPrediction
            and MoveIdentity(actualMove)
                == MoveIdentity(bestMove) then

            prediction =
                info.precomputedPrediction

        elseif Config.Mode == "Competitive" then
            -- Do not start a second large search after the time-controlled
            -- Competitive controller has already finished.
            prediction = nil

        else
            prediction =
                PredictEnemyReply(
                    info.position,
                    actualMove,
                    info.settings
                )
        end
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
                    or (
                        Config.Mode == "Competitive"
                        and "COMP"
                        or Config.Mode
                    )
            ),
            false
        )
    end

    if not autoSend then
        Config._Runtime.Thinking = false
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

        Config._Runtime.Thinking = false
        return false
    end

    local liveClient =
        FindMatchClient()

    if not liveClient then
        Config._Runtime.Thinking = false

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
            Config._Runtime.Thinking = false

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

        Config._Runtime.Thinking = false

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

        Config._Runtime.Thinking = false
        return false
    end

    LearningRecordOwnMove(
        liveMatch,
        info.position,
        actualMove,
        info,
        usedEmergency
            and "AI_EMERGENCY"
            or "AI"
    )

    -- PvP FIX:
    -- MovePiece.OnClientEvent does not reliably echo our own move.
    -- Without this local commit the shadow position stays one ply
    -- behind; the opponent's next move then fails conversion.
    if liveMatch.mode ~= "sunfish" then
        local shadowOK,
            shadowError =
            AdvanceShadowAfterOwnMove(
                liveMatch,
                actualMove,
                liveResolved.from,
                liveResolved.move,
                info.position
            )

        if not shadowOK then
            SetThinkingNarrative(
                "Nước đã được game gửi, nhưng Shadow không commit được: "
                .. tostring(shadowError)
                .. ". Tạm dừng AutoMove để tránh lệch bàn.",
                "warning"
            )

            SetStatus(
                "SHADOW COMMIT FAILED",
                true
            )

            Config._Runtime.Thinking = false
            return false
        end
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

    Config._Runtime.Thinking = false
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

        LearningPollResult()
        LearningSave(false)

        local match =
            GetCurrentMatch()

        if type(
            Learning.Neural
        ) == "table"
            and type(
                Learning.Neural.IdleTick
            ) == "function" then

            Learning.Neural.IdleTick(
                match
            )
        end

        if not match then
            SetHUDSleeping(true)

            if Config._Runtime.LastMatchId ~= nil then
                LearningPollResult()

                Config._Runtime.LastMatchId = nil
                Config._Runtime.LastAutoRound = nil
                ResetShadow(nil)
                ClearVisuals()
                ResetAnalysisHUD()
                UpdatePieceHUD(nil, nil)
            end

            if not Config._Runtime.Thinking then
                SetStatus(
                    "WAITING FOR MATCH",
                    false
                )
            end

            continue
        end

        SetHUDSleeping(false)

        if Config._Runtime.LastMatchId ~= match.id then
            Config._Runtime.LastMatchId = match.id
            Config._Runtime.LastAutoRound = nil
            ResetShadow(match)
            ResetAnalysisHUD()
            LearningStartSession(match)

            SetStatus(
                "MATCH "
                .. tostring(match.id),
                false
            )
        end

        if type(
            Learning.ProcessHistory
        ) == "function" then

            pcall(
                Learning.ProcessHistory,
                match
            )
        end

        if type(
            Learning.ProcessBotLiveLearning
        ) == "function" then

            pcall(
                Learning.ProcessBotLiveLearning,
                match
            )
        end

        if not Config.AutoMove
            or Config._Runtime.Thinking then

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
            if not Config._Runtime.Thinking then
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

        if Config._Runtime.LastAutoRound == roundKey then
            continue
        end

        Config._Runtime.LastAutoRound = roundKey

        task.spawn(
            function()
                local success =
                    Analyze(true)

                if not success then
                    -- Allow a retry if this was a temporary state.
                    task.delay(
                        0.8,
                        function()
                            if Config._Runtime.LastAutoRound
                                == roundKey then

                                Config._Runtime.LastAutoRound = nil
                            end
                        end
                    )
                end
            end
        )
    end
end)

SetExpanded(false)
SetHUDSleeping(true)
SetStatus("READY", false)

print(
    "[ChessAI] v6.0.1 loaded • Result + Bot Teacher/Neural fix",
    "| Mode:",
    Config.Mode,
    "| Memory:",
    Learning.persistent
        and "persistent"
        or "RAM",
    "| Save:",
    LearningStorage.memoryPath,
    "| NN:",
    string.format(
        "%d samples / %d updates / %.0f%%",
        #Learning.Neural.replay.samples,
        tonumber(
            Learning.Neural.stats.updates
        ) or 0,
        Learning.Neural.Confidence()
            * 100
    ),
    "| Remote:",
    MovePieceRemote:GetFullName()
)
