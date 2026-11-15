--[[
================================================================================
  CHESS AUTO-PLAY  (Roblox executor script)
  - GUI menu kéo-thả được, bo góc, tối ưu cho điện thoại
  - Auto Play Chess: tự đọc bàn cờ -> engine minimax alpha-beta -> đi nước hợp lý
  - Delay ngắn giả lập người, tự co lại khi sắp hết giờ
  - Bypass anti-cheat client (hook Kick, chặn remote report, disable script AC)
  - Tự nhận diện bàn cờ theo thứ tự: FEN -> Workspace parts -> GUI -> Remote
--------------------------------------------------------------------------------
  CÁCH DÙNG:
    1. Mở game cờ trên Roblox, vào bàn đấu.
    2. Chạy script này bằng executor (Delta / Fluxus / Syn / ...).
    3. Menu hiện góc phải trên. Bật "Auto Play Chess".
    4. Nếu game lạ không tự nhận diện được, bật Debug trong menu để xem
       adapter nào được chọn và FEN đọc được, rồi chỉnh CONFIG bên dưới.

  LƯU Ý KỸ THUẬT:
    - Mỗi game cờ Roblox lưu bàn cờ khác nhau. Script thử 4 kiểu đọc:
        (a) FEN: StringValue / Attribute khớp mẫu FEN  (chính xác nhất)
        (b) Workspace: 64 ô là BasePart (tên a1..h8 hoặc lưới 8x8)
        (c) GUI: 64 ImageButton/Frame (tên a1..h8 hoặc lưới 8x8)
        (d) Remote: tự fire RemoteEvent nếu tìm thấy
    - Nếu quân cờ là ảnh (ImageLabel) và không có FEN, cần điền
      CONFIG.ImagePieceMap (assetId -> "wP"/"bK"/...) sau khi xem Debug.
    - Đi nước: ưu tiên RemoteEvent; nếu không có thì click thật bằng
      VirtualUser (giống input người) rồi fallback fireclickdetector.
================================================================================
]]

--==============================================================================
-- KIỂM TRA TRẠNG THÁI SCRIPT (online / ngưng hoạt động)
-- Trang trạng thái: https://anotepad.com/notes/f9f3kywg
--   - nội dung ghi "online"  -> script chạy
--   - nội dung khác           -> báo "Script đã ngưng hoạt động" và dừng
--==============================================================================
local STATUS_URL = "https://anotepad.com/notes/f9f3kywg"

local function httpGet(url)
	local fns = {
		function() return game:HttpGet(url) end,
		function() return game:HttpGetAsync(url) end,
		function() return HttpGet(url) end,
		function() return request({ Url = url, Method = "GET" }).Body end,
		function() return http_request({ Url = url, Method = "GET" }).Body end,
		function() return syn.request({ Url = url, Method = "GET" }).Body end,
		function() return http.request({ Url = url, Method = "GET" }).Body end,
	}
	for _, f in ipairs(fns) do
		local ok, res = pcall(f)
		if ok and type(res) == "string" and #res > 0 then return res end
	end
	return nil
end

local function scriptIsOnline()
	for attempt = 1, 2 do
		local body = httpGet(STATUS_URL)
		if body then
			-- nội dung note nằm trong <div class="plaintext ...">...</div>
			local note = body:match('class="plaintext[^"]*">%s*(.-)%s*</div>')
			if note then
				note = note:gsub("<[^>]->", ""):lower()
				return note:find("online", 1, true) ~= nil
			end
			return body:lower():find(">online<", 1, true) ~= nil
		end
		pcall(function() task.wait(1) end)
	end
	return false
end

if not scriptIsOnline() then
	local msg = "Script đã ngưng hoạt động"
	pcall(function()
		game:GetService("StarterGui"):SetCore("SendNotification", {
			Title = "Chess Auto",
			Text = msg,
			Duration = 10,
		})
	end)
	warn("[Chess Auto] " .. msg)
	return
end


--==============================================================================
-- SERVICES
--==============================================================================
local Players      = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService   = game:GetService("RunService")
local LP           = Players.LocalPlayer

--==============================================================================
-- CONFIG
--==============================================================================
local CONFIG = {
	-- Bạn cầm quân gì: "auto" | "white" | "black"
	-- "auto" = tự nhận theo ván (khuyến nghị, vì mỗi ván có thể đổi màu)
	MyColor = "auto",

	-- Bàn cờ có bị xoay không. Khi MyColor="auto" script tự đặt lại giá trị này.
	BoardFlip = false,

	-- Độ sâu tìm kiếm. 2 = nhanh/yếu, 3 = cân bằng (khuyến nghị), 4 = mạnh/chậm
	Depth = 3,

	-- Giới hạn thời gian suy nghĩ mỗi nước (giây). Tự co lại khi sắp hết giờ.
	TimeLimit = 1.5,

	-- Delay giả lập người: ngẫu nhiên trong khoảng này (giây)
	MoveDelayMin = 1.5,
	MoveDelayMax = 2.5,

	-- Xác suất chọn nước không phải best (nhưng vẫn trong BlunderWindow centipawn)
	BlunderChance = 0.10,
	BlunderWindow = 70,

	-- Phong cấp: luôn lên Hậu
	AutoQueen = true,

	-- ===== ADAPTER OVERRIDE =====
	-- "auto" | "fen" | "workspace" | "gui" | "remote"
	AdapterMode = "auto",

	-- Nếu biết tên RemoteEvent đi nước, điền vào đây (ưu tiên hơn auto-detect)
	RemoteName = nil,
	-- Tự dò remote đi nước theo tên (move/chess/play). Mặc định TẮT vì mỗi game
	-- dùng format tham số khác nhau, gửi sai có thể không đi được hoặc bị đánh dấu.
	UseAutoRemote = false,
	-- Dùng API client của game (ChessClient.Session/BoardView) để đi nước trước,
	-- không được thì tự chuyển sang input ảo (click/kéo).
	UseGameAPI = true,
	-- Định dạng tham số remote: "fromto" (a1,b2) | "indices" (1,10) | "uci" ("a1b2")
	RemoteFormat = "fromto",

	-- Nếu bàn cờ có tên quân đặc biệt, map thêm ở đây:
	-- ["TênPartHoặcImage"] = "wP" / "bN" / ... (w=white, b=black)
	PieceNameMap = {},

	-- Nếu quân cờ là ảnh: [assetIdString] = "wP" / "bK" / ...
	ImagePieceMap = {},

	-- In log ra console
	Verbose = true,

	-- ===== BYPASS =====
	-- Chặn Kick luôn bật (an toàn, không ảnh hưởng gameplay)
	BypassKick = true,
	-- Chặn remote báo cáo/anti-cheat: MẶC ĐỊNH TẮT vì dễ chặn nhầm
	-- (bật trong menu "AC Bypass" nếu cần)
	BypassBlockRemotes = false,
	-- Tắt LocalScript anti-cheat: MẶC ĐỊNH TẮT vì có thể làm hỏng UI/game
	BypassDisableScripts = false,
	-- Mẫu tên remote bị chặn khi bật BypassBlockRemotes (cố tình hẹp)
	BypassPatterns = {
		"anticheat", "anti_cheat", "anti-cheat", "acreport", "reportcheat",
		"banplayer", "kickplayer", "detectcheat", "cheatdetect",
	},
}

--==============================================================================
-- UTIL
--==============================================================================
local LOG_BUFFER = {}
local function log(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
	local line = table.concat(parts, " ")
	LOG_BUFFER[#LOG_BUFFER + 1] = line
	if #LOG_BUFFER > 200 then table.remove(LOG_BUFFER, 1) end
	if CONFIG.Verbose then
		print("[Chess]", line)
	end
end

local function getLogs()
	return LOG_BUFFER
end

local function setStatus(s)
	if _G.__ChessAutoSetStatus then
		_G.__ChessAutoSetStatus(s)
	end
	log(s)
end

local function clamp(v, a, b)
	if v < a then return a end
	if v > b then return b end
	return v
end

local function round(n)
	return math.floor(n + 0.5)
end

-- file/rank <-> index  (index 1..64, 1 = a1, 64 = h8)
local function fileOf(i) return (i - 1) % 8 end
local function rankOf(i) return math.floor((i - 1) / 8) end
local function idxOf(f, r) return r * 8 + f + 1 end
local function inb(f, r) return f >= 0 and f < 8 and r >= 0 and r < 8 end
local function sqName(i)
	local f, r = fileOf(i), rankOf(i)
	return string.char(97 + f) .. tostring(r + 1)
end
local function nameToIdx(n)
	n = n:lower()
	local f = string.byte(n, 1) - 96
	local r = tonumber(n:sub(2, 2))
	if not f or not r then return nil end
	if f < 1 or f > 8 or r < 1 or r > 8 then return nil end
	return idxOf(f - 1, r - 1)
end

local function boardHash(b, turn)
	local t = {}
	for i = 1, 64 do t[i] = tostring(b[i] or 0) end
	return table.concat(t, ",") .. "|" .. tostring(turn)
end

-- Thế cờ xuất phát chuẩn (để biết ai đi trước khi chưa đọc được đồng hồ)
local START_B = {}
do
	local back = { 4, 2, 3, 5, 6, 3, 2, 4 }
	for f = 0, 7 do
		START_B[idxOf(f, 0)] = back[f + 1]
		START_B[idxOf(f, 1)] = 1
		START_B[idxOf(f, 6)] = -1
		START_B[idxOf(f, 7)] = -back[f + 1]
	end
end
local function isStartPos(b)
	for i = 1, 64 do
		if (b[i] or 0) ~= START_B[i] then return false end
	end
	return true
end

-- Đối thủ (-side) có quân vừa rời ô nào đó không? Dùng để chắc chắn lượt đã
-- chuyển sang đối thủ thay vì nhầm nước của chính mình thành nước đối thủ.
local function opponentMoved(exp, nb, side)
	if not exp or not nb then return false end
	local opp = -side
	for i = 1, 64 do
		local a, c = exp[i] or 0, nb[i] or 0
		if a ~= c and a ~= 0 and ((a > 0) == (opp > 0)) then return true end
	end
	return false
end

--==============================================================================
-- BYPASS ANTI-CHEAT
--==============================================================================
local Bypass = {}

Bypass.blockRemotes = false
Bypass.kickBlocked = 0
Bypass.remotesBlocked = 0

local function matchesAny(name, list)
	local n = name:lower()
	for _, p in ipairs(list) do
		if n:find(p, 1, true) then return true end
	end
	return false
end

-- Hook __namecall: LUÔN chặn Kick (an toàn).
-- Chỉ chặn FireServer tới remote báo cáo khi Bypass.blockRemotes = true.
-- Việc chặn FireServer mặc định TẮT vì rất dễ chặn nhầm remote gameplay
-- (gây đứng game / không tìm được user / không chơi tay được).
function Bypass.hookNamecall()
	local ok = pcall(function()
		local mt = getrawmetatable(game)
		local old = mt.__namecall
		if getreadonly and getreadonly(mt) then setreadonly(mt, false) end
		mt.__namecall = newcclosure(function(self, ...)
			local method = getnamecallmethod()
			if method == "Kick" and (self == LP or self == Players) then
				Bypass.kickBlocked = Bypass.kickBlocked + 1
				log("Bypass: chặn Kick")
				return
			end
			if Bypass.blockRemotes and method == "FireServer" and typeof(self) == "Instance"
				and (self:IsA("RemoteEvent") or self:IsA("UnreliableRemoteEvent")) then
				if matchesAny(self.Name, CONFIG.BypassPatterns) then
					Bypass.remotesBlocked = Bypass.remotesBlocked + 1
					log("Bypass: chặn FireServer ->", self:GetFullName())
					return
				end
			end
			return old(self, ...)
		end)
		if setreadonly then setreadonly(mt, true) end
	end)
	if not ok then
		log("Bypass: không hook được __namecall (executor hạn chế)")
	end
end

-- Hook trực tiếp hàm Kick nếu executor hỗ trợ hookfunction
function Bypass.hookKick()
	if not CONFIG.BypassKick then return end
	pcall(function()
		local old
		old = hookfunction(LP.Kick, function(self, msg)
			if self == LP then
				Bypass.kickBlocked = Bypass.kickBlocked + 1
				log("Bypass: Kick() bị chặn:", tostring(msg))
				return
			end
			return old(self, msg)
		end)
	end)
end

-- Tắt LocalScript anti-cheat phía client (chỉ khi được bật rõ ràng)
function Bypass.disableAntiCheatScripts()
	if not CONFIG.BypassDisableScripts then return end
	local roots = {}
	pcall(function() table.insert(roots, LP:FindFirstChild("PlayerScripts")) end)
	pcall(function() table.insert(roots, game:GetService("ReplicatedFirst")) end)
	pcall(function() table.insert(roots, ReplicatedStorage) end)

	local disabled = 0
	for _, root in ipairs(roots) do
		if root then
			for _, d in ipairs(root:GetDescendants()) do
				if d:IsA("LocalScript") or d:IsA("Script") then
					if matchesAny(d.Name, CONFIG.BypassPatterns) then
						pcall(function() d.Disabled = true end)
						pcall(function() d:Destroy() end)
						disabled = disabled + 1
					end
				end
			end
		end
	end
	if disabled > 0 then
		log("Bypass: tắt", disabled, "script anti-cheat")
	end
end

-- Chống AFK (nhiều game kick khi treo máy lâu)
function Bypass.antiAFK()
	pcall(function()
		LP.Idled:Connect(function()
			pcall(function()
				local VU = game:GetService("VirtualUser")
				VU:CaptureController()
				VU:ClickButton2(Vector2.new())
			end)
		end)
	end)
end

-- Hook các hàm hay bị dùng để phát hiện teleport/click ảo
function Bypass.softHooks()
	pcall(function()
		if hookfunction and getgenv then
			getgenv().__chessBypassLoaded = true
		end
	end)
end

-- Bật phần bypass mạnh (chặn remote báo cáo + tắt script AC)
function Bypass.aggressive(on)
	if on then
		Bypass.blockRemotes = true
		CONFIG.BypassDisableScripts = true
		Bypass.disableAntiCheatScripts()
		log("Bypass: bật chế độ mạnh (có thể ảnh hưởng game)")
	else
		Bypass.blockRemotes = false
		log("Bypass: tắt chặn remote (an toàn)")
	end
end

function Bypass.init()
	Bypass.hookNamecall()
	Bypass.hookKick()
	Bypass.disableAntiCheatScripts()
	Bypass.antiAFK()
	Bypass.softHooks()
	log("Bypass: khởi tạo xong (chặn Kick: " .. tostring(CONFIG.BypassKick)
		.. ", chặn remote: " .. tostring(Bypass.blockRemotes) .. ")")
end

--==============================================================================
-- CHESS ENGINE
--==============================================================================
local Engine = {}

local P, N, B, R, Q, K = 1, 2, 3, 4, 5, 6

local PIECE_VALUE = { [P] = 100, [N] = 320, [B] = 330, [R] = 500, [Q] = 900, [K] = 20000 }

-- PST: thứ tự rank8 -> rank1 (trắng nhìn từ dưới lên)
local PST = {}
PST[P] = {
	  0,  0,  0,  0,  0,  0,  0,  0,
	 50, 50, 50, 50, 50, 50, 50, 50,
	 10, 10, 20, 30, 30, 20, 10, 10,
	  5,  5, 10, 25, 25, 10,  5,  5,
	  0,  0,  0, 20, 20,  0,  0,  0,
	  5, -5,-10,  0,  0,-10, -5,  5,
	  5, 10, 10,-20,-20, 10, 10,  5,
	  0,  0,  0,  0,  0,  0,  0,  0,
}
PST[N] = {
	-50,-40,-30,-30,-30,-30,-40,-50,
	-40,-20,  0,  0,  0,  0,-20,-40,
	-30,  0, 10, 15, 15, 10,  0,-30,
	-30,  5, 15, 20, 20, 15,  5,-30,
	-30,  0, 15, 20, 20, 15,  0,-30,
	-30,  5, 10, 15, 15, 10,  5,-30,
	-40,-20,  0,  5,  5,  0,-20,-40,
	-50,-40,-30,-30,-30,-30,-40,-50,
}
PST[B] = {
	-20,-10,-10,-10,-10,-10,-10,-20,
	-10,  0,  0,  0,  0,  0,  0,-10,
	-10,  0,  5, 10, 10,  5,  0,-10,
	-10,  5,  5, 10, 10,  5,  5,-10,
	-10,  0, 10, 10, 10, 10,  0,-10,
	-10, 10, 10, 10, 10, 10, 10,-10,
	-10,  5,  0,  0,  0,  0,  5,-10,
	-20,-10,-10,-10,-10,-10,-10,-20,
}
PST[R] = {
	  0,  0,  0,  0,  0,  0,  0,  0,
	  5, 10, 10, 10, 10, 10, 10,  5,
	 -5,  0,  0,  0,  0,  0,  0, -5,
	 -5,  0,  0,  0,  0,  0,  0, -5,
	 -5,  0,  0,  0,  0,  0,  0, -5,
	 -5,  0,  0,  0,  0,  0,  0, -5,
	 -5,  0,  0,  0,  0,  0,  0, -5,
	  0,  0,  0,  5,  5,  0,  0,  0,
}
PST[Q] = {
	-20,-10,-10, -5, -5,-10,-10,-20,
	-10,  0,  0,  0,  0,  0,  0,-10,
	-10,  0,  5,  5,  5,  5,  0,-10,
	 -5,  0,  5,  5,  5,  5,  0, -5,
	  0,  0,  5,  5,  5,  5,  0, -5,
	-10,  5,  5,  5,  5,  5,  0,-10,
	-10,  0,  5,  0,  0,  0,  0,-10,
	-20,-10,-10, -5, -5,-10,-10,-20,
}
PST[K] = {
	-30,-40,-40,-50,-50,-40,-40,-30,
	-30,-40,-40,-50,-50,-40,-40,-30,
	-30,-40,-40,-50,-50,-40,-40,-30,
	-30,-40,-40,-50,-50,-40,-40,-30,
	-20,-30,-30,-40,-40,-30,-30,-20,
	-10,-20,-20,-20,-20,-20,-20,-10,
	 20, 20,  0,  0,  0,  0, 20, 20,
	 20, 30, 10,  0,  0, 10, 30, 20,
}

local function pstAt(pt, idx, white)
	local f = (idx - 1) % 8
	local r = math.floor((idx - 1) / 8)
	local row = white and (7 - r) or r
	return PST[pt][row * 8 + f + 1]
end

local KNIGHT_D = { {1,2},{2,1},{2,-1},{1,-2},{-1,-2},{-2,-1},{-2,1},{-1,2} }
local KING_D   = { {1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1},{0,-1},{1,-1} }
local BISHOP_D = { {1,1},{1,-1},{-1,-1},{-1,1} }
local ROOK_D   = { {1,0},{-1,0},{0,1},{0,-1} }

local function findKing(b, side)
	local target = side * K
	for i = 1, 64 do
		if b[i] == target then return i end
	end
	return nil
end

local function isAttacked(b, sq, by)
	local f, r = fileOf(sq), rankOf(sq)

	-- pawn
	local pd = (by == 1) and -1 or 1
	for _, df in ipairs({-1, 1}) do
		local ff, rr = f + df, r + pd
		if inb(ff, rr) and b[idxOf(ff, rr)] == by * P then return true end
	end
	-- knight
	for _, d in ipairs(KNIGHT_D) do
		local ff, rr = f + d[1], r + d[2]
		if inb(ff, rr) and b[idxOf(ff, rr)] == by * N then return true end
	end
	-- king
	for _, d in ipairs(KING_D) do
		local ff, rr = f + d[1], r + d[2]
		if inb(ff, rr) and b[idxOf(ff, rr)] == by * K then return true end
	end
	-- bishop / queen
	for _, d in ipairs(BISHOP_D) do
		local ff, rr = f + d[1], r + d[2]
		while inb(ff, rr) do
			local p = b[idxOf(ff, rr)]
			if p ~= 0 then
				if p == by * B or p == by * Q then return true end
				break
			end
			ff, rr = ff + d[1], rr + d[2]
		end
	end
	-- rook / queen
	for _, d in ipairs(ROOK_D) do
		local ff, rr = f + d[1], r + d[2]
		while inb(ff, rr) do
			local p = b[idxOf(ff, rr)]
			if p ~= 0 then
				if p == by * R or p == by * Q then return true end
				break
			end
			ff, rr = ff + d[1], rr + d[2]
		end
	end
	return false
end

-- Sinh nước đi giả hợp lệ
function Engine.genMoves(st, capturesOnly)
	local moves = {}
	local b, turn = st.b, st.turn

	local function addPawn(from, to, r1)
		if (turn == 1 and r1 == 7) or (turn == -1 and r1 == 0) then
			if CONFIG.AutoQueen then
				moves[#moves + 1] = { from = from, to = to, promo = Q }
			else
				moves[#moves + 1] = { from = from, to = to, promo = Q }
				moves[#moves + 1] = { from = from, to = to, promo = R }
				moves[#moves + 1] = { from = from, to = to, promo = B }
				moves[#moves + 1] = { from = from, to = to, promo = N }
			end
		else
			moves[#moves + 1] = { from = from, to = to }
		end
	end

	for i = 1, 64 do
		local p = b[i]
		if p ~= 0 and (p > 0) == (turn > 0) then
			local f, r = fileOf(i), rankOf(i)
			local pt = math.abs(p)

			if pt == P then
				local dirR = turn
				local r1 = r + dirR
				if r1 >= 0 and r1 < 8 then
					local one = idxOf(f, r1)
					if b[one] == 0 then
						if not capturesOnly then
							addPawn(i, one, r1)
							local startR = (turn == 1) and 1 or 6
							if r == startR then
								local two = idxOf(f, r + 2 * dirR)
								if b[two] == 0 then
									moves[#moves + 1] = { from = i, to = two }
								end
							end
						end
					end
					for _, df in ipairs({-1, 1}) do
						local ff = f + df
						if inb(ff, r1) then
							local t = idxOf(ff, r1)
							if b[t] ~= 0 and (b[t] > 0) ~= (turn > 0) then
								addPawn(i, t, r1)
							elseif st.ep == t then
								moves[#moves + 1] = { from = i, to = t, ep = true }
							end
						end
					end
				end

			elseif pt == N then
				for _, d in ipairs(KNIGHT_D) do
					local ff, rr = f + d[1], r + d[2]
					if inb(ff, rr) then
						local t = idxOf(ff, rr)
						local q = b[t]
						if q == 0 then
							if not capturesOnly then moves[#moves + 1] = { from = i, to = t } end
						elseif (q > 0) ~= (turn > 0) then
							moves[#moves + 1] = { from = i, to = t }
						end
					end
				end

			elseif pt == K then
				for _, d in ipairs(KING_D) do
					local ff, rr = f + d[1], r + d[2]
					if inb(ff, rr) then
						local t = idxOf(ff, rr)
						local q = b[t]
						if q == 0 then
							if not capturesOnly then moves[#moves + 1] = { from = i, to = t } end
						elseif (q > 0) ~= (turn > 0) then
							moves[#moves + 1] = { from = i, to = t }
						end
					end
				end

				if not capturesOnly then
					local homeRank = (turn == 1) and 0 or 7
					if r == homeRank and f == 4 then
						local wk = (turn == 1) and st.castle[1] or st.castle[3]
						local wq = (turn == 1) and st.castle[2] or st.castle[4]
						-- kingside
						if wk == 1
							and b[idxOf(5, homeRank)] == 0 and b[idxOf(6, homeRank)] == 0
							and b[idxOf(7, homeRank)] == turn * R
							and not isAttacked(b, i, -turn)
							and not isAttacked(b, idxOf(5, homeRank), -turn)
							and not isAttacked(b, idxOf(6, homeRank), -turn) then
							moves[#moves + 1] = { from = i, to = idxOf(6, homeRank), castle = "K" }
						end
						-- queenside
						if wq == 1
							and b[idxOf(3, homeRank)] == 0 and b[idxOf(2, homeRank)] == 0 and b[idxOf(1, homeRank)] == 0
							and b[idxOf(0, homeRank)] == turn * R
							and not isAttacked(b, i, -turn)
							and not isAttacked(b, idxOf(3, homeRank), -turn)
							and not isAttacked(b, idxOf(2, homeRank), -turn) then
							moves[#moves + 1] = { from = i, to = idxOf(2, homeRank), castle = "Q" }
						end
					end
				end

			else
				local dirs
				if pt == B then dirs = BISHOP_D
				elseif pt == R then dirs = ROOK_D
				else dirs = { {1,1},{1,-1},{-1,-1},{-1,1},{1,0},{-1,0},{0,1},{0,-1} } end

				for _, d in ipairs(dirs) do
					local ff, rr = f + d[1], r + d[2]
					while inb(ff, rr) do
						local t = idxOf(ff, rr)
						local q = b[t]
						if q == 0 then
							if not capturesOnly then moves[#moves + 1] = { from = i, to = t } end
						else
							if (q > 0) ~= (turn > 0) then
								moves[#moves + 1] = { from = i, to = t }
							end
							break
						end
						ff, rr = ff + d[1], rr + d[2]
					end
				end
			end
		end
	end

	return moves
end

function Engine.inCheck(st)
	local kp = findKing(st.b, st.turn)
	if not kp then return false end
	return isAttacked(st.b, kp, -st.turn)
end

function Engine.apply(st, m)
	local b = st.b
	local undo = {
		castle = { st.castle[1], st.castle[2], st.castle[3], st.castle[4] },
		ep = st.ep,
		captured = nil,
		capIdx = nil,
		half = st.half,
	}
	local p = b[m.from]
	local pt = math.abs(p)
	local turn = st.turn

	if m.ep then
		local capIdx = m.to - turn * 8
		undo.captured = b[capIdx]
		undo.capIdx = capIdx
		b[capIdx] = 0
	else
		undo.captured = b[m.to]
		undo.capIdx = m.to
	end

	b[m.to] = p
	b[m.from] = 0

	if m.promo then b[m.to] = turn * m.promo end

	if m.castle then
		local hr = (turn == 1) and 0 or 7
		if m.castle == "K" then
			b[idxOf(5, hr)] = b[idxOf(7, hr)]
			b[idxOf(7, hr)] = 0
		else
			b[idxOf(3, hr)] = b[idxOf(0, hr)]
			b[idxOf(0, hr)] = 0
		end
	end

	if pt == K then
		if turn == 1 then st.castle[1] = 0; st.castle[2] = 0
		else st.castle[3] = 0; st.castle[4] = 0 end
	end
	if pt == R then
		if m.from == idxOf(0, 0) then st.castle[2] = 0 end
		if m.from == idxOf(7, 0) then st.castle[1] = 0 end
		if m.from == idxOf(0, 7) then st.castle[4] = 0 end
		if m.from == idxOf(7, 7) then st.castle[3] = 0 end
	end
	if undo.captured and math.abs(undo.captured) == R then
		local ci = undo.capIdx
		if ci == idxOf(0, 0) then st.castle[2] = 0 end
		if ci == idxOf(7, 0) then st.castle[1] = 0 end
		if ci == idxOf(0, 7) then st.castle[4] = 0 end
		if ci == idxOf(7, 7) then st.castle[3] = 0 end
	end

	st.ep = nil
	if pt == P and math.abs(m.to - m.from) == 16 then
		st.ep = math.floor((m.from + m.to) / 2)
	end

	if pt == P or (undo.captured and undo.captured ~= 0) then
		st.half = 0
	else
		st.half = st.half + 1
	end

	st.turn = -turn
	return undo
end

function Engine.unapply(st, undo, m)
	local b = st.b
	st.turn = -st.turn
	local p = b[m.to]

	if m.promo then p = st.turn * P end

	b[m.from] = p
	b[m.to] = 0

	if m.ep then
		b[undo.capIdx] = undo.captured
	else
		b[undo.capIdx] = undo.captured
	end

	if m.castle then
		local hr = (st.turn == 1) and 0 or 7
		if m.castle == "K" then
			b[idxOf(7, hr)] = b[idxOf(5, hr)]
			b[idxOf(5, hr)] = 0
		else
			b[idxOf(0, hr)] = b[idxOf(3, hr)]
			b[idxOf(3, hr)] = 0
		end
	end

	st.castle[1] = undo.castle[1]
	st.castle[2] = undo.castle[2]
	st.castle[3] = undo.castle[3]
	st.castle[4] = undo.castle[4]
	st.ep = undo.ep
	st.half = undo.half
end

local function evaluate(st)
	local score = 0
	local b = st.b
	for i = 1, 64 do
		local p = b[i]
		if p ~= 0 then
			local pt = math.abs(p)
			local white = p > 0
			local v = PIECE_VALUE[pt] + pstAt(pt, i, white)
			if white then score = score + v else score = score - v end
		end
	end
	return score * st.turn
end

local function orderMoves(st, moves)
	local b = st.b
	for _, m in ipairs(moves) do
		local victim = b[m.to]
		local attacker = b[m.from]
		local s = 0
		if victim and victim ~= 0 then
			s = 10 * PIECE_VALUE[math.abs(victim)] - PIECE_VALUE[math.abs(attacker)]
		end
		if m.promo then s = s + PIECE_VALUE[m.promo] end
		if m.castle then s = s + 50 end
		m._s = s
	end
	table.sort(moves, function(a, b2) return (a._s or 0) > (b2._s or 0) end)
end

local function legalFilter(st, moves)
	local out = {}
	for _, m in ipairs(moves) do
		local u = Engine.apply(st, m)
		local mover = -st.turn
		local kp = findKing(st.b, mover)
		local legal = kp and not isAttacked(st.b, kp, st.turn)
		Engine.unapply(st, u, m)
		if legal then out[#out + 1] = m end
	end
	return out
end

function Engine.legalMoves(st)
	return legalFilter(st, Engine.genMoves(st, false))
end

local function quiesce(st, alpha, beta, ply)
	if os.clock() > (st.deadline or math.huge) then return evaluate(st) end

	local stand = evaluate(st)
	if stand >= beta then return beta end
	if stand > alpha then alpha = stand end

	local moves = legalFilter(st, Engine.genMoves(st, true))
	orderMoves(st, moves)

	for _, m in ipairs(moves) do
		local u = Engine.apply(st, m)
		local s = -quiesce(st, -beta, -alpha, ply + 1)
		Engine.unapply(st, u, m)
		if s >= beta then return beta end
		if s > alpha then alpha = s end
	end
	return alpha
end

local function search(st, depth, alpha, beta, ply)
	if os.clock() > (st.deadline or math.huge) then return evaluate(st) end

	local moves = legalFilter(st, Engine.genMoves(st, false))
	if #moves == 0 then
		if Engine.inCheck(st) then
			return -29000 + ply
		end
		return 0
	end

	if depth <= 0 then
		return quiesce(st, alpha, beta, ply)
	end

	orderMoves(st, moves)

	local best = -math.huge
	for _, m in ipairs(moves) do
		local u = Engine.apply(st, m)
		local s = -search(st, depth - 1, -beta, -alpha, ply + 1)
		Engine.unapply(st, u, m)
		if s > best then best = s end
		if s > alpha then alpha = s end
		if alpha >= beta then break end
	end
	return best
end

-- Trả về nước đi tốt nhất + bảng điểm (để debug)
function Engine.bestMove(st, opts)
	local t0 = os.clock()
	local maxDepth = math.max(1, opts.Depth or 3)
	st.deadline = t0 + (opts.TimeLimit or 4.0)

	local moves = Engine.legalMoves(st)
	if #moves == 0 then return nil, {} end
	orderMoves(st, moves)

	-- mức dự phòng: đánh giá tĩnh (luôn có nước đi dù hết thời gian)
	local scored = {}
	for _, m in ipairs(moves) do
		local u = Engine.apply(st, m)
		local s = -evaluate(st)
		Engine.unapply(st, u, m)
		scored[#scored + 1] = { m = m, s = s }
	end
	table.sort(scored, function(a, b2) return a.s > b2.s end)

	local ordered = {}
	for i, e in ipairs(scored) do ordered[i] = e.m end

	-- tăng dần độ sâu: hết giờ thì dùng kết quả độ sâu đã xong gần nhất
	for d = 1, maxDepth do
		local cur = {}
		local aborted = false
		for _, m in ipairs(ordered) do
			if os.clock() > st.deadline then aborted = true; break end
			local u = Engine.apply(st, m)
			local s = -search(st, d - 1, -math.huge, math.huge, 1)
			Engine.unapply(st, u, m)
			cur[#cur + 1] = { m = m, s = s }
		end
		if aborted then break end
		table.sort(cur, function(a, b2) return a.s > b2.s end)
		scored = cur
		for i, e in ipairs(cur) do ordered[i] = e.m end
	end

	local best = scored[1].s
	local pool = {}
	for _, e in ipairs(scored) do
		if best - e.s <= (opts.BlunderWindow or 70) then
			pool[#pool + 1] = e
		end
	end

	local pick
	if #pool > 1 and math.random() < (opts.BlunderChance or 0.1) then
		pick = pool[math.random(2, #pool)]
	else
		pick = pool[1]
	end

	return pick.m, scored
end

-- FEN
local FEN_MAP = {
	p = -P, n = -N, b = -B, r = -R, q = -Q, k = -K,
	P = P,  N = N,  B = B,  R = R,  Q = Q,  K = K,
}

function Engine.parseFEN(fen)
	fen = fen:gsub("^%s+", ""):gsub("%s+$", "")
	local parts = string.split(fen, " ")
	if #parts < 1 then return nil end

	local rows = string.split(parts[1], "/")
	if #rows ~= 8 then return nil end

	local b = {}
	for i = 1, 64 do b[i] = 0 end

	for ri, row in ipairs(rows) do
		local rank = 8 - ri -- 0-based rank
		local f = 0
		for ci = 1, #row do
			local ch = row:sub(ci, ci)
			local num = tonumber(ch)
			if num then
				f = f + num
			else
				local code = FEN_MAP[ch]
				if code and f < 8 then
					b[idxOf(f, rank)] = code
					f = f + 1
				else
					f = f + 1
				end
			end
		end
	end

	local turn = (parts[2] == "b") and -1 or 1

	local castle = { 0, 0, 0, 0 }
	local cs = parts[3] or "-"
	if cs:find("K", 1, true) then castle[1] = 1 end
	if cs:find("Q", 1, true) then castle[2] = 1 end
	if cs:find("k", 1, true) then castle[3] = 1 end
	if cs:find("q", 1, true) then castle[4] = 1 end

	local ep = nil
	local epStr = parts[4]
	if epStr and epStr ~= "-" then ep = nameToIdx(epStr) end

	return {
		b = b,
		turn = turn,
		castle = castle,
		ep = ep,
		half = 0,
		full = 1,
	}
end

--==============================================================================
-- ADAPTERS
--==============================================================================
local Adapter = {}

local PIECE_KEYWORDS = {
	{ P, { "pawn", "tốt", "tot" } },
	{ N, { "knight", "horse", "mã", "ma" } },
	{ B, { "bishop", "tượng", "tuong" } },
	{ R, { "rook", "castle", "xe" } },
	{ Q, { "queen", "hậu", "hau" } },
	{ K, { "king", "vua" } },
}

local function identifyPieceType(name)
	name = name:lower()
	if CONFIG.PieceNameMap[name] then return CONFIG.PieceNameMap[name] end

	for _, entry in ipairs(PIECE_KEYWORDS) do
		for _, kw in ipairs(entry[2]) do
			if name:find(kw, 1, true) then return entry[1] end
		end
	end
	-- mã 1 ký tự
	if #name <= 3 then
		if name:find("p") then return P end
		if name:find("n") or name:find("h") then return N end
		if name:find("b") then return B end
		if name:find("r") then return R end
		if name:find("q") then return Q end
		if name:find("k") then return K end
	end
	return nil
end

local function identifyColor(name, part)
	name = name:lower()
	if name:find("white", 1, true) or name:find("trắng", 1, true) or name:find("trang", 1, true) then
		return 1
	end
	if name:find("black", 1, true) or name:find("đen", 1, true) or name:find("den", 1, true) then
		return -1
	end
	if part then
		local ok, c = pcall(function() return part.Color end)
		if ok and c then
			local lum = 0.299 * c.R + 0.587 * c.G + 0.114 * c.B
			if lum > 0.55 then return 1 elseif lum < 0.45 then return -1 end
		end
	end
	return nil
end

local function encodePiece(name, part)
	local pt = identifyPieceType(name)
	if not pt then return nil end
	local color = identifyColor(name, part)
	if not color then return nil end
	return color * pt
end

-- ----- FEN source -----
local FEN_ATTR_NAMES = { "FEN", "fen", "Fen", "BoardFEN", "boardFEN", "Board", "board" }

local function looksLikeFEN(v)
	return type(v) == "string" and select(2, v:gsub("/", "")) == 7
end

-- forward declaration: GameAPI được định nghĩa sau, adapter dùng trước
local GameAPI
local Turn

local function findFENSource()
	local candidates = { workspace, ReplicatedStorage }
	pcall(function()
		local pg = LP:FindFirstChild("PlayerGui")
		if pg then table.insert(candidates, pg) end
	end)

	-- 1) StringValue chứa FEN
	for _, root in ipairs(candidates) do
		local found = nil
		pcall(function()
			for _, d in ipairs(root:GetDescendants()) do
				if d:IsA("StringValue") and looksLikeFEN(d.Value) then
					found = { obj = d, kind = "value" }
					break
				end
			end
		end)
		if found then return found end
	end

	-- 2) Attribute FEN trên Instance
	for _, root in ipairs(candidates) do
		local found = nil
		pcall(function()
			for _, d in ipairs(root:GetDescendants()) do
				for _, an in ipairs(FEN_ATTR_NAMES) do
					local ok, v = pcall(function() return d:GetAttribute(an) end)
					if ok and looksLikeFEN(v) then
						found = { obj = d, kind = "attr", attr = an }
						break
					end
				end
				if found then break end
			end
		end)
		if found then return found end
	end

	return nil
end

local function readFENSource(src)
	if not src then return nil end
	if src.kind == "value" then
		if not src.obj.Parent then return nil end
		return src.obj.Value
	else
		local ok, v = pcall(function() return src.obj:GetAttribute(src.attr) end)
		return ok and v or nil
	end
end

local function describeFENSource(src)
	if not src then return "không tìm thấy FEN" end
	if src.kind == "value" then
		return src.obj:GetFullName() .. " = " .. tostring(src.obj.Value)
	else
		return src.obj:GetFullName() .. " [attribute " .. src.attr .. "] = "
			.. tostring(readFENSource(src))
	end
end

local function makeFENAdapter()
	local cached = nil
	return {
		name = "FEN",
		read = function()
			if not cached or (cached.kind == "value" and not cached.obj.Parent) then
				cached = findFENSource()
			end
			local v = readFENSource(cached)
			if not v then return nil end
			local st = Engine.parseFEN(v)
			if not st then return nil end
			return st.b, st.turn
		end,
		play = function() return false end, -- FEN chỉ đọc
	}
end

-- ----- Workspace adapter -----
local function findSquareParts()
	local best, bestScore = nil, 0
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("BasePart") then
			local par = d.Parent
			if par then
				local squares, total = {}, 0
				for _, c in ipairs(par:GetChildren()) do
					if c:IsA("BasePart") then
						total = total + 1
						if c.Name:match("^[a-hA-H][1-8]$") then
							squares[#squares + 1] = c
						end
					end
				end
				if #squares >= 32 and #squares > bestScore then
					best, bestScore = par, #squares
				end
			end
		end
	end
	return best
end

local function buildSquareMapFromNames(root)
	local map = {}
	for _, c in ipairs(root:GetChildren()) do
		if c:IsA("BasePart") then
			local idx = nameToIdx(c.Name)
			if idx then map[idx] = c end
		end
	end
	return map
end

local function buildSquareMapFromGrid(root)
	-- Lấy tất cả part, tìm lưới 8x8 theo X/Z
	local parts = {}
	for _, c in ipairs(root:GetDescendants()) do
		if c:IsA("BasePart") then parts[#parts + 1] = c end
	end
	if #parts < 64 then return nil end

	-- Lọc part phẳng (ô cờ) dựa trên kích thước gần bằng nhau
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, p in ipairs(parts) do
		local pos = p.Position
		minX = math.min(minX, pos.X); maxX = math.max(maxX, pos.X)
		minZ = math.min(minZ, pos.Z); maxZ = math.max(maxZ, pos.Z)
	end
	local w = (maxX - minX) / 8
	local h = (maxZ - minZ) / 8
	if w <= 0 or h <= 0 then return nil end

	local map = {}
	local used = {}
	for idx = 1, 64 do
		local f, r = fileOf(idx), rankOf(idx)
		local targetX = minX + (f + 0.5) * w
		local targetZ = minZ + ((CONFIG.BoardFlip and (7 - r) or r) + 0.5) * h
		local bestPart, bestDist = nil, math.huge
		for _, p in ipairs(parts) do
			if not used[p] then
				local dx = p.Position.X - targetX
				local dz = p.Position.Z - targetZ
				local dist = dx * dx + dz * dz
				if dist < bestDist then bestDist, bestPart = dist, p end
			end
		end
		if bestPart then
			map[idx] = bestPart
			used[bestPart] = true
		end
	end
	return map
end

local function readWorkspaceBoard(root, squareMap)
	local b = {}
	for i = 1, 64 do b[i] = 0 end

	-- Quân cờ: part nằm trong root (hoặc folder con) mà không phải ô cờ
	local squareSet = {}
	for _, p in pairs(squareMap) do squareSet[p] = true end

	local maxY = -math.huge
	for _, sp in pairs(squareMap) do maxY = math.max(maxY, sp.Position.Y) end

	local function assignPiece(part)
		local idx = nil
		-- tìm ô gần nhất theo X/Z
		local bestDist = math.huge
		for si, sp in pairs(squareMap) do
			local dx = sp.Position.X - part.Position.X
			local dz = sp.Position.Z - part.Position.Z
			local dist = dx * dx + dz * dz
			if dist < bestDist then bestDist, idx = dist, si end
		end
		if not idx then return end
		local code = encodePiece(part.Name, part)
		if not code then
			-- thử con của part (model quân cờ)
			for _, ch in ipairs(part:GetDescendants()) do
				if ch:IsA("BasePart") or ch:IsA("Decal") or ch:IsA("Texture") then
					code = encodePiece(ch.Name, ch:IsA("BasePart") and ch or part)
					if code then break end
				end
			end
		end
		if code then b[idx] = code end
	end

	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and not squareSet[d] then
			-- bỏ qua part quá thấp (mặt bàn)
			if d.Position.Y > maxY - 0.5 then
				assignPiece(d)
			end
		elseif d:IsA("Model") then
			-- model quân cờ
			local prim = d.PrimaryPart or d:FindFirstChildWhichIsA("BasePart")
			if prim and not squareSet[prim] then
				local code = encodePiece(d.Name, prim)
				if code then
					local idx, bestDist = nil, math.huge
					for si, sp in pairs(squareMap) do
						local dx = sp.Position.X - prim.Position.X
						local dz = sp.Position.Z - prim.Position.Z
						local dist = dx * dx + dz * dz
						if dist < bestDist then bestDist, idx = dist, si end
					end
					if idx then b[idx] = code end
				end
			end
		end
	end

	return b
end

local function clickPart(part)
	-- 1) click thật bằng VirtualUser (giống người)
	local cam = workspace.CurrentCamera
	if cam then
		local sp, onScreen = cam:WorldToViewportPoint(part.Position)
		if onScreen then
			local ok = pcall(function()
				local VU = game:GetService("VirtualUser")
				VU:CaptureController()
				VU:ClickButton1(Vector2.new(sp.X, sp.Y))
			end)
			if ok then return true end
		end
	end
	-- 2) fireclickdetector
	local cd = part:FindFirstChildWhichIsA("ClickDetector")
	if cd then
		local ok = pcall(function() fireclickdetector(cd) end)
		if ok then return true end
	end
	return false
end

local function makeWorkspaceAdapter()
	local root = findSquareParts()
	if not root then return nil end

	local squareMap = buildSquareMapFromNames(root)
	if not squareMap or next(squareMap) == nil then
		squareMap = buildSquareMapFromGrid(root)
	end
	if not squareMap then return nil end

	log("Workspace adapter:", root:GetFullName())

	return {
		name = "Workspace",
		root = root,
		squareMap = squareMap,
		read = function()
			return readWorkspaceBoard(root, squareMap), nil
		end,
		play = function(from, to)
			local a, b = squareMap[from], squareMap[to]
			if not a or not b then return false end
			clickPart(a)
			task.wait(0.25)
			clickPart(b)
			return true
		end,
	}
end

-- ----- GUI adapter -----
-- Tìm container bàn cờ: ưu tiên 64 ô có tên a1..h8, fallback 64 ô cùng kích thước.
local function findGuiBoard()
	local pGui = LP:FindFirstChild("PlayerGui")
	if not pGui then return nil end

	local best, bestSquares = nil, nil
	for _, d in ipairs(pGui:GetDescendants()) do
		if d:IsA("GuiObject") then
			local named = {}
			for _, c in ipairs(d:GetDescendants()) do
				if c:IsA("GuiObject") and c.Name:match("^[a-hA-H][1-8]$") then
					named[#named + 1] = c
				end
			end
			if #named >= 32 and (not bestSquares or #named > #bestSquares) then
				best, bestSquares = d, named
			end
		end
	end
	if bestSquares then return best, bestSquares, "named" end

	-- fallback 1: container có đúng 64 con GuiObject
	for _, d in ipairs(pGui:GetDescendants()) do
		if d:IsA("GuiObject") then
			local kids = {}
			for _, c in ipairs(d:GetChildren()) do
				if c:IsA("GuiObject") then kids[#kids + 1] = c end
			end
			if #kids == 64 then
				return d, kids, "grid"
			end
		end
	end

	-- fallback 2: tìm cụm 64 ô cùng kích thước xếp thành 8x8 ở bất kỳ đâu
	local objs = {}
	for _, d in ipairs(pGui:GetDescendants()) do
		if d:IsA("GuiObject") and d.Visible ~= false then
			local s = d.AbsoluteSize
			if s and s.X >= 16 and s.Y >= 16 and s.X < 200 and s.Y < 200 then
				objs[#objs + 1] = d
			end
		end
	end
	local groups = {}
	for _, o in ipairs(objs) do
		local key = math.floor(o.AbsoluteSize.X / 6) .. "x" .. math.floor(o.AbsoluteSize.Y / 6)
		groups[key] = groups[key] or {}
		table.insert(groups[key], o)
	end
	for _, list in pairs(groups) do
		if #list >= 60 and #list <= 80 then
			local xs, ys = {}, {}
			for _, o in ipairs(list) do
				local p = o.AbsolutePosition
				local s = o.AbsoluteSize
				xs[#xs + 1] = p.X + s.X / 2
				ys[#ys + 1] = p.Y + s.Y / 2
			end
			local function cluster(vals, tol)
				table.sort(vals)
				local c = { vals[1] }
				for i = 2, #vals do
					if vals[i] - vals[i - 1] > tol then c[#c + 1] = vals[i] end
				end
				return c
			end
			local cell = list[1].AbsoluteSize
			local xc = cluster(xs, math.max(4, cell.X * 0.5))
			local yc = cluster(ys, math.max(4, cell.Y * 0.5))
			if #xc == 8 and #yc == 8 then
				return list[1].Parent, list, "tiles"
			end
		end
	end

	return nil
end

local function guiCenter(obj)
	local p = obj.AbsolutePosition
	local s = obj.AbsoluteSize
	return p.X + s.X / 2, p.Y + s.Y / 2
end

local function buildGuiMap(root, squares, kind)
	local map = {}
	if kind == "named" then
		for _, sq in ipairs(squares) do
			local idx = nameToIdx(sq.Name)
			if idx then map[idx] = sq end
		end
		if next(map) ~= nil then return map end
	end

	-- xếp theo lưới 8x8 dựa trên tâm các ô (bounding box)
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	for _, sq in ipairs(squares) do
		local cx, cy = guiCenter(sq)
		minX = math.min(minX, cx); maxX = math.max(maxX, cx)
		minY = math.min(minY, cy); maxY = math.max(maxY, cy)
	end
	local spanX = math.max(1, maxX - minX)
	local spanY = math.max(1, maxY - minY)

	for _, sq in ipairs(squares) do
		local cx, cy = guiCenter(sq)
		local col = clamp(round((cx - minX) / spanX * 7), 0, 7)
		local row = clamp(round((cy - minY) / spanY * 7), 0, 7)
		local file, rank
		if CONFIG.BoardFlip then
			file = 7 - col
			rank = row
		else
			file = col
			rank = 7 - row
		end
		map[idxOf(file, rank)] = sq
	end
	return map
end

-- Unicode cờ (♔..♟) -> mã quân
local GLYPH = {
	["\226\153\148"] = 6,   -- ♔ white king
	["\226\153\149"] = 5,   -- ♕ white queen
	["\226\153\150"] = 4,   -- ♖ white rook
	["\226\153\151"] = 3,   -- ♗ white bishop
	["\226\153\152"] = 2,   -- ♘ white knight
	["\226\153\153"] = 1,   -- ♙ white pawn
	["\226\153\154"] = -6,  -- ♚ black king
	["\226\153\155"] = -5,  -- ♛ black queen
	["\226\153\156"] = -4,  -- ♜ black rook
	["\226\153\157"] = -3,  -- ♝ black bishop
	["\226\153\158"] = -2,  -- ♞ black knight
	["\226\153\159"] = -1,  -- ♟ black pawn
}

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function glyphCode(text, color3)
	if type(text) ~= "string" then return nil end
	text = trim(text)
	local g = GLYPH[text]
	if not g then return nil end
	-- Nếu glyph là bộ đen nhưng chữ sáng => game tô màu, coi là trắng (và ngược lại)
	if color3 then
		local lum = 0.299 * color3.R + 0.587 * color3.G + 0.114 * color3.B
		if g < 0 and lum > 0.6 then return -g end
		if g > 0 and lum < 0.35 then return -g end
	end
	return g
end

local function colorFromAncestors(obj)
	local p = obj.Parent
	local depth = 0
	while p and depth < 6 do
		local n = p.Name:lower()
		if n:find("white", 1, true) or n:find("trắng", 1, true) then return 1 end
		if n:find("black", 1, true) or n:find("đen", 1, true) then return -1 end
		p = p.Parent
		depth = depth + 1
	end
	return nil
end

-- Bản đồ asset mặc định của game (học từ thế cờ xuất phát). Dùng khi vào ván
-- giữa chừng nên chưa kịp auto-learn. Auto-learn (CONFIG.ImagePieceMap) ưu tiên hơn.
local DEFAULT_IMAGE_MAP = {
	["rbxassetid://130108347060797"] = 1,
	["rbxassetid://111025513068016"] = 2,
	["rbxassetid://85269847273836"] = 3,
	["rbxassetid://133288029788689"] = 4,
	["rbxassetid://128494764910602"] = 5,
	["rbxassetid://108253639129512"] = 6,
	["rbxassetid://71167246324478"] = -1,
	["rbxassetid://104573159846789"] = -2,
	["rbxassetid://72796651173850"] = -3,
	["rbxassetid://92908975354335"] = -4,
	["rbxassetid://87797543393819"] = -5,
	["rbxassetid://99364349373891"] = -6,
}

local function assetCode(a)
	if not a or a == "" then return nil end
	return CONFIG.ImagePieceMap[a] or DEFAULT_IMAGE_MAP[a]
end

local function pieceFromObj(obj)
	-- chính nó là ảnh
	if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
		local asset = obj.Image and tostring(obj.Image) or nil
		if asset and asset ~= "" then
			local code = assetCode(asset) or encodePiece(obj.Name, nil)
			if code then return code, asset, obj.Name end
		end
	end
	-- chính nó là chữ (unicode cờ)
	if obj:IsA("TextLabel") or obj:IsA("TextButton") then
		local code = glyphCode(obj.Text, obj.TextColor3)
		if code then return code, nil, obj.Name end
	end

	for _, c in ipairs(obj:GetDescendants()) do
		if c:IsA("ImageLabel") or c:IsA("ImageButton") then
			local asset = c.Image and tostring(c.Image) or nil
			local code = assetCode(asset) or encodePiece(c.Name, nil)
			if code then return code, asset, c.Name end
		end
		if c:IsA("TextLabel") or c:IsA("TextButton") then
			local code = glyphCode(c.Text, c.TextColor3)
			if code then return code, nil, c.Name end
		end
	end

	-- theo tên (P/N/B/R/Q/K) + màu từ tên hoặc tổ tiên
	local pt = identifyPieceType(obj.Name)
	if pt then
		local color = identifyColor(obj.Name, nil) or colorFromAncestors(obj)
		if color then return color * pt, nil, obj.Name end
	end
	return nil
end

local function readGuiBoard(root, map)
	local b = {}
	for i = 1, 64 do b[i] = 0 end

	local found = 0
	for idx, sq in pairs(map) do
		local code = pieceFromObj(sq)
		if code then
			b[idx] = code
			found = found + 1
		end
	end

	-- fallback: quân nằm rời trong board (không phải con của ô)
	if found == 0 then
		local inMap = {}
		for _, sq in pairs(map) do inMap[sq] = true end

		local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
		for _, sq in pairs(map) do
			local cx, cy = guiCenter(sq)
			minX = math.min(minX, cx); maxX = math.max(maxX, cx)
			minY = math.min(minY, cy); maxY = math.max(maxY, cy)
		end
		local spanX = math.max(1, maxX - minX)
		local spanY = math.max(1, maxY - minY)

		local function cellOf(obj)
			local cx, cy = guiCenter(obj)
			local col = clamp(round((cx - minX) / spanX * 7), 0, 7)
			local row = clamp(round((cy - minY) / spanY * 7), 0, 7)
			local file, rank
			if CONFIG.BoardFlip then file, rank = 7 - col, row
			else file, rank = col, 7 - row end
			return idxOf(file, rank)
		end

		for _, d in ipairs(root:GetDescendants()) do
			if not inMap[d] then
				local code
				if d:IsA("ImageLabel") or d:IsA("ImageButton") then
					local asset = d.Image and tostring(d.Image) or nil
					code = assetCode(asset) or encodePiece(d.Name, nil)
				elseif d:IsA("TextLabel") or d:IsA("TextButton") then
					code = glyphCode(d.Text, d.TextColor3) or encodePiece(d.Name, nil)
				end
				if code then b[cellOf(d)] = code end
			end
		end
	end

	return b
end

-- Click bằng input ảo tại toạ độ tuyệt đối (giống chạm tay)
local function vclick(x, y)
	-- 1) API executor phổ biến (Delta/Fluxus/Krnl...)
	if type(mouse1click) == "function" then
		if pcall(mouse1click, x, y) then return true end
	end
	if type(mousemoveabs) == "function" and type(mouse1down) == "function"
		and type(mouse1up) == "function" then
		local ok = pcall(function()
			mousemoveabs(x, y)
			mouse1down()
			mouse1up()
		end)
		if ok then return true end
	end
	-- 2) VirtualUser
	local ok = pcall(function()
		local VU = game:GetService("VirtualUser")
		VU:CaptureController()
		VU:ClickButton1(Vector2.new(x, y))
	end)
	if ok then return true end
	-- 3) VirtualInputManager (một số executor cho phép)
	return pcall(function()
		local VIM = game:GetService("VirtualInputManager")
		VIM:SendMouseButtonEvent(x, y, 0, true, game, 1)
		VIM:SendMouseButtonEvent(x, y, 0, false, game, 1)
	end)
end

-- Tìm lớp phủ nhận input của bàn cờ (Board.Input)
local function getBoardInput()
	local pGui = LP:FindFirstChild("PlayerGui")
	if not pGui then return nil end
	for _, d in ipairs(pGui:GetDescendants()) do
		if d.Name == "Input" and d:IsA("GuiButton") then return d end
	end
	return nil
end

-- Kéo-thả ảo từ ô này sang ô kia (game dùng InputBegan/InputEnded)
local function vdrag(x1, y1, x2, y2)
	-- 1) API executor: giữ chuột, di, thả
	if type(mousemoveabs) == "function" and type(mouse1down) == "function"
		and type(mouse1up) == "function" then
		local ok = pcall(function()
			mousemoveabs(x1, y1)
			mouse1down()
			mousemoveabs(x2, y2)
			mouse1up()
		end)
		if ok then return true end
	end
	-- 2) VirtualInputManager: down -> move -> up
	local ok = pcall(function()
		local VIM = game:GetService("VirtualInputManager")
		VIM:SendMouseButtonEvent(x1, y1, 0, true, game, 1)
		VIM:SendMouseMoveEvent(x2, y2, game)
		VIM:SendMouseButtonEvent(x2, y2, 0, false, game, 1)
	end)
	if ok then return true end
	-- 3) bắn signal InputBegan/InputEnded với InputObject giả (Mouse + Touch)
	if firesignal then
		local input = getBoardInput()
		if input then
			local function fire(typ, ev, st, x, y)
				local sig = input[ev]
				if not sig then return false end
				return pcall(firesignal, sig, {
					Position = Vector3.new(x, y, 0),
					UserInputType = typ,
					UserInputState = st,
				})
			end
			for _, typ in ipairs({ Enum.UserInputType.Touch, Enum.UserInputType.MouseButton1 }) do
				local a = fire(typ, "InputBegan", Enum.UserInputState.Begin, x1, y1)
				fire(typ, "InputChanged", Enum.UserInputState.Change, x2, y2)
				local b = fire(typ, "InputEnded", Enum.UserInputState.End, x2, y2)
				if a and b then return true end
			end
		end
	end
	return false
end

-- Click lên một GuiObject: ưu tiên bắn signal (chạy được cả khi VirtualUser bị chặn)
local function clickObject(obj)
	if not obj then return false end
	if firesignal then
		if obj:IsA("GuiButton") then
			for _, ev in ipairs({ "MouseButton1Click", "Activated", "MouseButton1Down" }) do
				local sig = obj[ev]
				if sig and pcall(firesignal, sig) then return true end
			end
		end
		-- nhiều game bắt InputBegan của ô/quân
		if obj.InputBegan then
			local ok = pcall(function()
				local input = Instance.new("InputObject")
				input.UserInputType = Enum.UserInputType.MouseButton1
				input.UserInputState = Enum.UserInputState.Begin
				input.Position = Vector3.new(0, 0, 0)
				firesignal(obj.InputBegan, input)
			end)
			if ok then return true end
		end
	end
	local cx, cy = guiCenter(obj)
	return vclick(cx, cy)
end

local function clickGui(obj)
	if clickObject(obj) then return true end
	local cx, cy = guiCenter(obj)
	return vclick(cx, cy)
end

-- Tự học assetId quân cờ từ thế cờ xuất phát (nếu quân là ảnh và chưa có map)
local BACK_RANK = { R, N, B, Q, K, B, N, R }

-- assets: { [idx] = assetId }. Trả về true nếu học được.
local function learnFromAssetMap(assets)
	if next(CONFIG.ImagePieceMap) ~= nil then return false end

	local occupied = 0
	for _ in pairs(assets) do occupied = occupied + 1 end
	if occupied ~= 32 then return false end

	local learned = {}
	local function place(rank, file, code)
		local a = assets[idxOf(file, rank)]
		if not a then return false end
		if learned[a] and learned[a] ~= code then return false end
		learned[a] = code
		return true
	end

	for file = 0, 7 do
		if not place(0, file, BACK_RANK[file + 1]) then return false end
		if not place(1, file, P) then return false end
		if not place(6, file, -P) then return false end
		if not place(7, file, -BACK_RANK[file + 1]) then return false end
	end

	-- không được có quân ngoài 4 hàng xuất phát
	for idx in pairs(assets) do
		local r = rankOf(idx)
		if not (r == 0 or r == 1 or r == 6 or r == 7) then return false end
	end

	local n = 0
	for a, c in pairs(learned) do
		CONFIG.ImagePieceMap[a] = c
		n = n + 1
	end
	log("Auto-learned", n, "piece image assets từ thế cờ xuất phát")
	return true
end

local function tryLearnImagePieces(map)
	if next(CONFIG.ImagePieceMap) ~= nil then return false end
	local assets = {}
	for idx, sq in pairs(map) do
		for _, c in ipairs(sq:GetDescendants()) do
			if (c:IsA("ImageLabel") or c:IsA("ImageButton"))
				and c.Image and tostring(c.Image) ~= "" then
				assets[idx] = tostring(c.Image)
				break
			end
		end
	end
	return learnFromAssetMap(assets)
end

local function makeGuiAdapter()
	local root, squares, kind = findGuiBoard()
	if not root or not squares then return nil end

	local map = buildGuiMap(root, squares, kind)
	if next(map) == nil then return nil end

	log("GUI adapter:", root:GetFullName(), "#squares=", #squares, "kind=", kind, "#map=", (function()
		local n = 0; for _ in pairs(map) do n = n + 1 end; return n
	end)())

	return {
		name = "GUI",
		root = root,
		map = map,
		kind = kind,
		read = function()
			tryLearnImagePieces(map)
			return readGuiBoard(root, map), nil
		end,
		play = function(from, to)
			local a, b = map[from], map[to]
			if not a or not b then return false end
			clickGui(a)
			task.wait(0.25)
			clickGui(b)
			return true
		end,
	}
end

-- ----- Flat board adapter: nền bàn cờ 1 ảnh + quân rời đặt theo toạ độ -----
local DECOR_NAMES = {
	shade = true, art = true, floater = true, glow = true, dots = true,
	vignette = true, image = true, background = true, bg = true, border = true,
	shadow = true, gradient = true, overlay = true, highlight = true,
	selection = true, marker = true, outline = true, blur = true, texture = true,
	line = true, grid = true, gridline = true, effect = true, particle = true,
}

local function isDecor(obj)
	return DECOR_NAMES[obj.Name:lower()] == true
end

local function isPieceish(obj)
	if not obj:IsA("GuiObject") then return false end
	if isDecor(obj) then return false end
	if identifyPieceType(obj.Name) then return true end
	if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
		local img = obj.Image and tostring(obj.Image) or ""
		if img ~= "" then return true end
	end
	if obj:IsA("TextLabel") or obj:IsA("TextButton") then
		if glyphCode(obj.Text, obj.TextColor3) then return true end
	end
	return false
end

local function smallPiece(o)
	if not isPieceish(o) then return false end
	local s = o.AbsoluteSize
	return s and s.X <= 130 and s.Y <= 130
end

local function findFlatBoard()
	local pGui = LP:FindFirstChild("PlayerGui")
	if not pGui then return nil end
	local best, bestN = nil, 0
	for _, d in ipairs(pGui:GetDescendants()) do
		if d:IsA("GuiObject") and d.Visible ~= false and not isDecor(d) then
			local s = d.AbsoluteSize
			if s and s.X >= 150 and s.Y >= 150 and s.X / s.Y > 0.72 and s.X / s.Y < 1.38 then
				local n = 0
				for _, c in ipairs(d:GetDescendants()) do
					if isPieceish(c) then n = n + 1 end
				end
				if n >= 4 and n > bestN then best, bestN = d, n end
			end
		end
	end
	if best then
		return { x = best.AbsolutePosition.X, y = best.AbsolutePosition.Y,
			w = best.AbsoluteSize.X, h = best.AbsoluteSize.Y }, best, bestN, "container"
	end

	-- fallback: bỏ qua container, suy bàn cờ từ bounding box của tất cả quân
	local pieces = {}
	for _, d in ipairs(pGui:GetDescendants()) do
		if smallPiece(d) then pieces[#pieces + 1] = d end
	end
	if #pieces < 16 then return nil end

	local xs, ys = {}, {}
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	for _, p in ipairs(pieces) do
		local cx, cy = guiCenter(p)
		xs[#xs + 1] = cx
		ys[#ys + 1] = cy
		minX = math.min(minX, cx); maxX = math.max(maxX, cx)
		minY = math.min(minY, cy); maxY = math.max(maxY, cy)
	end
	table.sort(xs)
	table.sort(ys)
	local function medianGap(v)
		local gaps = {}
		for i = 2, #v do
			local g = v[i] - v[i - 1]
			if g > 2 then gaps[#gaps + 1] = g end
		end
		if #gaps == 0 then return 1 end
		table.sort(gaps)
		return gaps[math.floor(#gaps / 2) + 1]
	end
	local cell = medianGap(xs)
	if cell <= 2 then cell = medianGap(ys) end
	if cell <= 2 then cell = (maxX - minX) / 7 end
	if cell <= 2 then return nil end

	local w = math.max(cell * 8, maxX - minX + cell)
	local h = math.max(cell * 8, maxY - minY + cell)
	return { x = minX - cell / 2, y = minY - cell / 2, w = w, h = h }, nil, #pieces, "bbox"
end

local function makeFlatAdapter()
	local rect, board, pieceCount, mode = findFlatBoard()
	if not rect then return nil end

	local function piecesOf()
		if board then
			local out = {}
			for _, c in ipairs(board:GetDescendants()) do
				if isPieceish(c) then out[#out + 1] = c end
			end
			return out
		end
		local out = {}
		local pGui = LP:FindFirstChild("PlayerGui")
		if pGui then
			for _, c in ipairs(pGui:GetDescendants()) do
				if smallPiece(c) then out[#out + 1] = c end
			end
		end
		return out
	end

	local function cellOf(obj)
		local cw, ch = math.max(1, rect.w / 8), math.max(1, rect.h / 8)
		local cx, cy = guiCenter(obj)
		local col = clamp(math.floor((cx - rect.x) / cw), 0, 7)
		local row = clamp(math.floor((cy - rect.y) / ch), 0, 7)
		local file, rank
		if CONFIG.BoardFlip then file, rank = 7 - col, row
		else file, rank = col, 7 - row end
		return idxOf(file, rank)
	end

	local function centerOf(idx)
		local f, r = fileOf(idx), rankOf(idx)
		local col, row
		if CONFIG.BoardFlip then col, row = 7 - f, r
		else col, row = f, 7 - r end
		return Vector2.new(rect.x + (col + 0.5) * rect.w / 8, rect.y + (row + 0.5) * rect.h / 8)
	end

	log("Flat board adapter:", board and board:GetFullName() or "(bbox)", "mode=", mode,
		"#pieces=", pieceCount)

	-- Các ô bấm được (GuiButton/ô có kích thước ~1 ô) để bắn click chính xác
	local cachedSquares = nil
	local function squareMap()
		if cachedSquares then return cachedSquares end
		local map = {}
		local root = board
		if not root then
			local pGui = LP:FindFirstChild("PlayerGui")
			root = pGui
		end
		if not root then return map end
		local cw, ch = rect.w / 8, rect.h / 8
		local candidates = {}
		for _, d in ipairs(root:GetDescendants()) do
			if d ~= board and d:IsA("GuiObject") and not isPieceish(d) and d.Visible ~= false then
				local s = d.AbsoluteSize
				if s and s.X >= cw * 0.5 and s.X <= cw * 1.6
					and s.Y >= ch * 0.5 and s.Y <= ch * 1.6 then
					candidates[#candidates + 1] = d
				end
			end
		end
		-- ưu tiên GuiButton
		table.sort(candidates, function(a, b)
			local ab = a:IsA("GuiButton") and 1 or 0
			local bb = b:IsA("GuiButton") and 1 or 0
			return ab > bb
		end)
		for _, d in ipairs(candidates) do
			local idx = cellOf(d)
			if not map[idx] then map[idx] = d end
		end
		cachedSquares = map
		return map
	end

	local function learnFlat()
		if next(CONFIG.ImagePieceMap) ~= nil then return false end
		local assets = {}
		for _, c in ipairs(piecesOf()) do
			local img = c.Image and tostring(c.Image) or ""
			if img ~= "" then assets[cellOf(c)] = img end
		end
		return learnFromAssetMap(assets)
	end

	local function readBoard()
		learnFlat()
		local b = {}
		for i = 1, 64 do b[i] = 0 end
		for _, c in ipairs(piecesOf()) do
			local code = pieceFromObj(c)
			if code then b[cellOf(c)] = code end
		end
		return b, nil
	end

	return {
		name = "GUI-flat",
		root = board,
		kind = "flat",
		read = readBoard,
		play = function(from, to)
			-- 1) đi qua API thật của game (BoardView/Session), kiểm tra bàn đổi
			if CONFIG.UseGameAPI ~= false and GameAPI then
				local before = boardHash(readBoard(), nil)
				local ok, how = GameAPI.attemptMoves(from, to, function()
					return boardHash(readBoard(), nil) ~= before
				end)
				if ok then
					log("Move:", how)
					return true
				end
			end
			-- 2) dự phòng: kéo-thả ảo rồi click ảo (đều kiểm tra bàn đổi)
			local p1, p2 = centerOf(from), centerOf(to)
			local before2 = boardHash(readBoard(), nil)
			local function changed2()
				return boardHash(readBoard(), nil) ~= before2
			end
			if vdrag(p1.X, p1.Y, p2.X, p2.Y) then
				task.wait(0.4)
				if changed2() then
					log("Move: vdrag")
					return true
				end
			end
			if vclick(p1.X, p1.Y) then
				task.wait(0.25)
				if vclick(p2.X, p2.Y) then
					task.wait(0.4)
					if changed2() then
						log("Move: vclick2")
						return true
					end
				end
			end
			-- 3) bắn click lên ô/quân
			local cmap = squareMap()
			local function tap(idx)
				local obj = cmap[idx]
				if obj then return clickObject(obj) end
				local p = centerOf(idx)
				return vclick(p.X, p.Y)
			end
			tap(from)
			task.wait(0.4)
			tap(to)
			return true
		end,
	}
end

-- ----- Remote -----
local function findMoveRemote()
	if CONFIG.RemoteName then
		local found = ReplicatedStorage:FindFirstChild(CONFIG.RemoteName, true)
		if found and (found:IsA("RemoteEvent") or found:IsA("RemoteFunction")) then
			return found
		end
	end
	for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
		if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
			local n = d.Name:lower()
			if n:find("move", 1, true) or n:find("chess", 1, true) or n:find("play", 1, true) then
				return d
			end
		end
	end
	return nil
end

local function fireRemote(remote, from, to)
	local fmt = CONFIG.RemoteFormat
	local ok
	if fmt == "indices" then
		ok = pcall(function() remote:FireServer(from, to) end)
	elseif fmt == "uci" then
		ok = pcall(function() remote:FireServer(sqName(from) .. sqName(to)) end)
	else
		ok = pcall(function() remote:FireServer(sqName(from), sqName(to)) end)
	end
	return ok
end

-- Gắn remote vào adapter hiện có (để ưu tiên đi nước bằng remote)
local function attachRemote(adapter)
	-- Chỉ tự dùng remote khi được chỉ định rõ (format tham số mỗi game khác nhau).
	if not CONFIG.RemoteName and not CONFIG.UseAutoRemote then return adapter end
	local remote = findMoveRemote()
	if not remote then return adapter end
	log("Dùng remote:", remote:GetFullName())
	local oldPlay = adapter.play
	adapter.play = function(from, to)
		if fireRemote(remote, from, to) then return true end
		return oldPlay(from, to)
	end
	return adapter
end

function Adapter.detect()
	local mode = CONFIG.AdapterMode

	local fenAdapter = nil
	if mode == "auto" or mode == "fen" then
		local fa = makeFENAdapter()
		if fa and fa.read() then fenAdapter = fa end
	end

	local ws, gui, flat
	if mode == "auto" or mode == "workspace" then
		ws = makeWorkspaceAdapter()
	end
	if mode == "auto" or mode == "gui" then
		gui = makeGuiAdapter()
	end
	if mode == "auto" or mode == "gui" or mode == "flat" then
		flat = makeFlatAdapter()
	end

	local playAdapter = ws or gui or flat
	if playAdapter then
		playAdapter = attachRemote(playAdapter)
		-- Nếu có FEN thì dùng FEN để đọc bàn (chính xác nhất), adapter kia để đi nước
		if fenAdapter then
			playAdapter.read = fenAdapter.read
			playAdapter.name = playAdapter.name .. " + FEN"
		end
		return playAdapter
	end

	if fenAdapter then
		return fenAdapter
	end

	return nil
end

--==============================================================================
-- GAME API: dùng module client của chính game (Session/BoardView)
-- để biết màu và đi nước, không phụ thuộc click ảo.
--==============================================================================
GameAPI = { _session = nil, _boardView = nil, _bv = nil, _sess = nil }

local function clientFolder()
	return ReplicatedStorage:FindFirstChild("ChessClient")
end

local function requireModule(name)
	local f = clientFolder()
	local mod = f and f:FindFirstChild(name)
	if not mod or not mod:IsA("ModuleScript") then return nil end
	local ok, m = pcall(require, mod)
	if ok and type(m) == "table" then return m end
	return nil
end

function GameAPI.session()
	if GameAPI._session == nil then
		GameAPI._session = requireModule("Session") or false
	end
	return GameAPI._session or nil
end

function GameAPI.boardView()
	if GameAPI._boardView == nil then
		GameAPI._boardView = requireModule("BoardView") or false
	end
	return GameAPI._boardView or nil
end

-- Đọc hướng bàn từ Board.Coords: nhãn ở góc dưới-trái là file gì.
-- "a" -> Trắng ở dưới (không xoay); "h" -> bàn xoay (Đen ở dưới).
function GameAPI.coordsFlip()
	local pGui = LP:FindFirstChild("PlayerGui")
	if not pGui then return nil end
	local coords = pGui:FindFirstChild("Coords", true)
	if not coords then return nil end
	local best, bestScore = nil, -math.huge
	for _, d in ipairs(coords:GetDescendants()) do
		if d:IsA("TextLabel") then
			local t = d.Text
			if type(t) == "string" and t:match("^%s*[a-h]%s*$") then
				t = t:match("[a-h]")
				local p = d.AbsolutePosition
				if p then
					-- ưu tiên x nhỏ (trái) và y lớn (dưới)
					local score = -p.X + p.Y
					if score > bestScore then best, bestScore = t, score end
				end
			end
		end
	end
	if best == "a" then return false end
	if best == "h" then return true end
	return nil
end

-- Quét upvalue của handler để tìm instance thật (BoardView/Session)
local function collectUpvalueTables(getup, fn, want, out, depth)
	if type(fn) ~= "function" then return end
	for i = 1, 60 do
		local ok, n, v = pcall(getup, fn, i)
		if not ok or not n then break end
		if type(v) == "table" then
			if v[want] ~= nil then out[v] = true end
			if depth > 1 then
				for _, vv in pairs(v) do
					if type(vv) == "table" and vv[want] ~= nil then out[vv] = true end
				end
			end
		end
	end
end

local function signalConnections(sig)
	local getconn = getconnections or (debug and debug.getconnections)
	if not getconn then return nil end
	local ok, conns = pcall(getconn, sig)
	if ok and type(conns) == "table" then return conns end
	return nil
end

-- Quét garbage collector để tìm instance thật của class (không phải bảng class).
local function scanGC(pred)
	local gc = getgc or (debug and debug.getgc)
	if not gc then return nil end
	local ok, list = pcall(gc, true)
	if not ok or type(list) ~= "table" then return nil end
	for _, v in pairs(list) do
		if type(v) == "table" then
			local okp, hit = pcall(pred, v)
			if okp and hit then return v end
		end
	end
	return nil
end

function GameAPI.findBoardView()
	if GameAPI._bv then return GameAPI._bv end
	if GameAPI._bvMiss and os.clock() - GameAPI._bvMiss < 3 then return nil end

	-- 1) GC: instance BoardView (có method, không có __index của class)
	local inst = scanGC(function(v)
		return type(v.pressSquare) == "function"
			and type(v.tryMove) == "function"
			and type(v.paint) == "function"
			and v.__index == nil
	end)
	if inst then
		GameAPI._bv = inst
		return inst
	end

	local getup = getupvalue or (debug and debug.getupvalue)
	if getup then
		local pGui = LP:FindFirstChild("PlayerGui")
		local board = pGui and pGui:FindFirstChild("Board", true)
		if board then
			local out = {}
			local objs = {}
			for _, d in ipairs(board:GetDescendants()) do
				if d.Name == "Input" or d.Name:match("^S%d+$") then
					objs[#objs + 1] = d
					if #objs >= 12 then break end
				end
			end
			for _, o in ipairs(objs) do
				for _, sn in ipairs({ "InputBegan", "InputEnded", "InputChanged",
					"MouseButton1Click", "Activated" }) do
					local okSig, sig = pcall(function() return o[sn] end)
					if okSig and sig then
						local conns = signalConnections(sig)
						if conns then
							for _, c in ipairs(conns) do
								local fn = c.Function or c["function"]
								pcall(collectUpvalueTables, getup, fn, "pressSquare", out, 2)
								pcall(collectUpvalueTables, getup, fn, "tryMove", out, 2)
							end
						end
					end
				end
			end
			for t in pairs(out) do
				GameAPI._bv = t
				return t
			end
		end
	end
	-- fallback: field trong App
	local app = requireModule("App")
	if app then
		for _, v in pairs(app) do
			if type(v) == "table" and type(v.pressSquare) == "function" then
				GameAPI._bv = v
				return v
			end
		end
	end
	GameAPI._bvMiss = os.clock()
	return nil
end

function GameAPI.findSession()
	if GameAPI._sess then return GameAPI._sess end
	if GameAPI._sessMiss and os.clock() - GameAPI._sessMiss < 3 then return nil end

	-- 1) GC: instance Session
	local inst = scanGC(function(v)
		return type(v.isMyTurn) == "function"
			and type(v.ply) == "function"
			and (type(v.applyUci) == "function" or type(v.sideToMove) == "function")
			and v.__index == nil
	end)
	if inst then
		GameAPI._sess = inst
		return inst
	end

	local bv = GameAPI.findBoardView()
	if bv then
		for _, k in ipairs({ "session", "sess", "game", "state", "model" }) do
			local v = bv[k]
			if type(v) == "table"
				and (type(v.isMyTurn) == "function" or type(v.applyUci) == "function") then
				GameAPI._sess = v
				return v
			end
		end
		-- quét mọi field (kể cả lồng 1 cấp) tìm Session
		for _, v in pairs(bv) do
			if type(v) == "table" then
				if type(v.isMyTurn) == "function" or type(v.applyUci) == "function" then
					GameAPI._sess = v
					return v
				end
				for _, w in pairs(v) do
					if type(w) == "table"
						and (type(w.isMyTurn) == "function" or type(w.applyUci) == "function") then
						GameAPI._sess = w
						return w
					end
				end
			end
		end
	end
	GameAPI._sessMiss = os.clock()
	return nil
end

local COLOR_KEYS = {
	"myColor", "color", "side", "playerColor", "mySide", "localColor",
	"colorName", "playerSide", "isWhite",
}

local function colorFromValue(v)
	if v == "white" or v == "w" or v == "White" then return "white" end
	if v == "black" or v == "b" or v == "Black" then return "black" end
	if v == 1 then return "white" end
	if v == -1 then return "black" end
	return nil
end

function GameAPI.myColor()
	local s = GameAPI.findSession()
	if s then
		for _, k in ipairs(COLOR_KEYS) do
			local c = colorFromValue(s[k])
			if c then return c end
		end
		-- suy ra màu từ sideToMove + isMyTurn (không cần biết tên field)
		if type(s.sideToMove) == "function" and type(s.isMyTurn) == "function" then
			local ok1, side = pcall(s.sideToMove, s)
			local ok2, mine = pcall(s.isMyTurn, s)
			local c = colorFromValue(side)
			if ok1 and ok2 and c and type(mine) == "boolean" then
				if mine then return c end
				return (c == "white") and "black" or "white"
			end
		end
		for _, v in pairs(s) do
			if type(v) == "table" then
				for _, k in ipairs(COLOR_KEYS) do
					local c = colorFromValue(v[k])
					if c then return c end
				end
			end
		end
	end
	local bv = GameAPI.findBoardView()
	if bv then
		for _, k in ipairs(COLOR_KEYS) do
			local c = colorFromValue(bv[k])
			if c then return c end
		end
	end
	return nil
end

-- Thử nhiều cách đi nước qua API của game; verify() trả true nếu bàn đã đổi.
function GameAPI.attemptMoves(from, to, verify)
	local a, b = sqName(from), sqName(to)
	local s = GameAPI.findSession()
	local bv = GameAPI.findBoardView()
	local tries = {}
	local function add(name, fn) tries[#tries + 1] = { name = name, fn = fn } end

	if s then
		if type(s.applyUci) == "function" then
			add("session:applyUci", function() return s:applyUci(a .. b) end)
		end
		if type(s.applyMove) == "function" then
			add("session:applyMove", function()
				local m
				if type(s.findMoveAt) == "function" then
					local ok, r = pcall(s.findMoveAt, s, a, b)
					if ok then m = r end
				end
				if m then return s:applyMove(m) end
			end)
		end
	end

	if bv then
		if type(bv.tryMove) == "function" then
			add("bv:tryMove(a,b)", function() return bv:tryMove(a, b) end)
			add("bv:tryMove(i,i)", function() return bv:tryMove(from, to) end)
		end
		if type(bv.pointerDown) == "function" and type(bv.pointerUp) == "function" then
			add("bv:pointerDrag(a)", function()
				bv:pointerDown(a)
				if type(bv.pointerMove) == "function" then bv:pointerMove(b) end
				bv:pointerUp(b)
			end)
			add("bv:pointerDrag(i)", function()
				bv:pointerDown(from)
				if type(bv.pointerMove) == "function" then bv:pointerMove(to) end
				bv:pointerUp(to)
			end)
		end
		if type(bv.pressSquare) == "function" then
			add("bv:pressSquare(a)", function() bv:pressSquare(a); bv:pressSquare(b) end)
			add("bv:pressSquare(i)", function() bv:pressSquare(from); bv:pressSquare(to) end)
		end
	end

	for _, t in ipairs(tries) do
		local ok = pcall(t.fn)
		if ok then
			if not verify then return true, t.name end
			task.wait(0.4)
			if verify() then return true, t.name end
		end
	end
	return false
end

function GameAPI.playMove(from, to)
	return GameAPI.attemptMoves(from, to, nil)
end

-- giữ tên cũ
function GameAPI.tryMove(from, to)
	return GameAPI.playMove(from, to)
end

local function tableKeys(t, limit)
	local keys = {}
	for k, v in pairs(t) do
		if type(k) == "string" then keys[#keys + 1] = k .. ":" .. type(v) end
		if #keys >= (limit or 60) then break end
	end
	return table.concat(keys, ", ")
end

function GameAPI.dump()
	local out = {}
	for _, name in ipairs({ "Session", "BoardView" }) do
		local f = clientFolder()
		local mod = f and f:FindFirstChild(name)
		if mod then
			local ok, m = pcall(require, mod)
			out[#out + 1] = name .. " class: " .. (ok and type(m) or ("ERR " .. tostring(m)))
		else
			out[#out + 1] = name .. " module: missing"
		end
	end

	local bv = GameAPI.findBoardView()
	out[#out + 1] = "boardView instance: " .. (bv and "FOUND" or "nil")
	if bv then
		local keys = {}
		for k, v in pairs(bv) do
			if type(k) == "string" then keys[#keys + 1] = k .. ":" .. type(v) end
			if #keys >= 24 then break end
		end
		out[#out + 1] = "  bv fields: " .. table.concat(keys, ",")
		local function brief(t)
			if type(t) ~= "table" then return tostring(t) end
			local p = {}
			for k, v in pairs(t) do
				if type(v) ~= "table" and type(v) ~= "function" and type(v) ~= "userdata" then
					p[#p + 1] = tostring(k) .. "=" .. tostring(v)
				end
				if #p >= 6 then break end
			end
			return "{" .. table.concat(p, ",") .. "}"
		end
		out[#out + 1] = "  movable=" .. tostring(bv.movable)
			.. " lastMove=" .. brief(bv.lastMove)
			.. " position=" .. brief(bv.position)
			.. " realPosition=" .. brief(bv.realPosition)
	end
	local s = GameAPI.findSession()
	out[#out + 1] = "session instance: " .. (s and "FOUND" or "nil")
	if s then
		if type(s.sideToMove) == "function" then
			local ok, v = pcall(s.sideToMove, s)
			out[#out + 1] = "  sideToMove=" .. tostring(ok and v)
		end
		if type(s.isMyTurn) == "function" then
			local ok, v = pcall(s.isMyTurn, s)
			out[#out + 1] = "  isMyTurn=" .. tostring(ok and v)
		end
	end
	return out
end

--==============================================================================
-- DEBUG / CLIPBOARD
--==============================================================================
local state -- forward declaration (DebugTool + GUI + Controller dùng chung)
local DebugTool = {}

local function describeObj(o)
	local s = o.ClassName .. " '" .. o.Name .. "'"
	local ok = pcall(function()
		if o:IsA("GuiObject") then
			s = s .. string.format(" size=%.0fx%.0f pos=%.0f,%.0f",
				o.AbsoluteSize.X, o.AbsoluteSize.Y, o.AbsolutePosition.X, o.AbsolutePosition.Y)
		end
		if o:IsA("ImageLabel") or o:IsA("ImageButton") then
			s = s .. " img=" .. tostring(o.Image)
		end
		if o:IsA("TextLabel") or o:IsA("TextButton") then
			s = s .. " text=[" .. tostring(o.Text) .. "]"
		end
	end)
	return s
end

local function pushLine(L, ...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
	L[#L + 1] = table.concat(parts, " ")
end

function DebugTool.collect()
	local L = {}
	pushLine(L, "=== CHESS AUTO DEBUG ===")
	pushLine(L, "adapter:", state.adapter and state.adapter.name or "NIL",
		"| MyColor:", CONFIG.MyColor, "| side:", tostring(state.sideLocked),
		"| flip:", tostring(CONFIG.BoardFlip), "| depth:", CONFIG.Depth)
	pushLine(L, "running:", tostring(state.running), "| turn:", tostring(state.turnHint),
		"| coordsFlip:", tostring(GameAPI.coordsFlip()))
	pushLine(L, "instances: bv=", GameAPI._bv and "FOUND" or "nil",
		" sess=", GameAPI._sess and "FOUND" or "nil",
		" getgc=", tostring(getgc ~= nil),
		" getupvalue=", tostring(getupvalue ~= nil))
	pushLine(L, "input: mouse1click=", tostring(type(mouse1click)),
		" mousemoveabs=", tostring(type(mousemoveabs)),
		" VirtualUser=", tostring(pcall(function()
			return game:GetService("VirtualUser")
		end)),
		" firesignal=", tostring(firesignal ~= nil))
	local ipm = 0
	for _ in pairs(CONFIG.ImagePieceMap) do ipm = ipm + 1 end
	pushLine(L, "imageMap:", ipm, "(default 12) | kick:", tostring(CONFIG.BypassKick),
		"| kickBlocked:", Bypass.kickBlocked)
	pushLine(L, "")

	pushLine(L, "FEN:", describeFENSource(findFENSource()))
	pushLine(L, "")

	local pGui = LP:FindFirstChild("PlayerGui")
	if pGui then
		local frect, fboard, fcount, fmode = findFlatBoard()
		if frect then
			pushLine(L, "board:", fboard and fboard:GetFullName() or "(bbox)",
				" mode=", fmode, " #pieces=", fcount,
				string.format(" rect=%.0f,%.0f %.0fx%.0f", frect.x, frect.y, frect.w, frect.h))
		else
			pushLine(L, "board: none")
		end

		local coords = pGui:FindFirstChild("Coords", true)
		if coords then
			local parts = {}
			for _, d in ipairs(coords:GetChildren()) do
				if d:IsA("TextLabel") and d.Name:match("^File%d$") then
					local p = d.AbsolutePosition
					parts[#parts + 1] = d.Name .. "=" .. tostring(d.Text) ..
						(p and string.format("@%.0f,%.0f", p.X, p.Y) or "")
				end
			end
			pushLine(L, "coords:", table.concat(parts, " "))
		end

		if Turn then
			local clocks = Turn.findClocks()
			local cs = {}
			for _, c in ipairs(clocks) do
				local p = c.AbsolutePosition
				cs[#cs + 1] = tostring(c.Text) .. (p and string.format("@y%.0f", p.Y) or "")
			end
			pushLine(L, "clocks:", #cs > 0 and table.concat(cs, ", ") or "none")
		end

		if state.adapter then
			local okr, bb = pcall(state.adapter.read)
			if okr and bb then
				local list, n = {}, 0
				for i = 1, 64 do
					if bb[i] and bb[i] ~= 0 then
						n = n + 1
						if #list < 40 then list[#list + 1] = sqName(i) .. "=" .. tostring(bb[i]) end
					end
				end
				pushLine(L, "read #", n, ":", table.concat(list, " "))
			end
		end
	else
		pushLine(L, "no PlayerGui")
	end
	pushLine(L, "")

	pushLine(L, "--- CHESSCLIENT ---")
	pcall(function()
		for _, line in ipairs(GameAPI.dump()) do pushLine(L, "  ", line) end
	end)
	pushLine(L, "")

	pushLine(L, "--- LOG (40 cuoi) ---")
	local logs = getLogs()
	local first = math.max(1, #logs - 39)
	for i = first, #logs do pushLine(L, logs[i]) end

	return table.concat(L, "\n")
end

function DebugTool.copy()
	local txt = DebugTool.collect()
	local ok = false
	pcall(function()
		if setclipboard then setclipboard(txt); ok = true end
	end)
	if not ok then
		pcall(function()
			if toclipboard then toclipboard(txt); ok = true end
		end)
	end
	return txt, ok
end

--==============================================================================
-- GUI
--==============================================================================
local GUI = {}
local Controller -- forward declaration (GUI closures dùng Controller)
state = {
	running = false,
	adapter = nil,
	statusLabel = nil,
	toggleBtn = nil,
	logLabel = nil,
	main = nil,
	body = nil,
	minimized = false,
	debugOn = false,
	sideLocked = nil,
	sideProvisional = false,
}

--==============================================================================
-- SIDE DETECTION (tự nhận bạn cầm Trắng hay Đen)
--==============================================================================
-- Giả định: game luôn xoay bàn để NGƯỜI CHƠI ở phía dưới.
-- Ở thế xuất phát, Trắng đi trước. Nếu thấy đối thủ đi trước (bàn đổi khi ta
-- chưa đi) thì quân vừa đi là của Trắng -> biết Trắng ở trên hay dưới.
local SideDetect = { started = false, base = nil, t0 = 0 }

local function setFlip(flip)
	flip = flip and true or false
	if CONFIG.BoardFlip ~= flip then
		CONFIG.BoardFlip = flip
		for k in pairs(CONFIG.ImagePieceMap) do CONFIG.ImagePieceMap[k] = nil end
		state.adapter = nil
	end
end

local function applySide(color)
	color = (color == "black") and "black" or "white"
	state.sideLocked = color
	setFlip(color == "black")
	log("Phe:", color, "| BoardFlip:", tostring(CONFIG.BoardFlip))
end

function SideDetect.setSide(color)
	state.sideProvisional = false
	if color == "auto" then
		CONFIG.MyColor = "auto"
		state.sideLocked = nil
		SideDetect.reset()
		log("Phe: auto")
		return
	end
	CONFIG.MyColor = color
	applySide(color)
end

function SideDetect.reset()
	SideDetect.started = false
	SideDetect.base = nil
	SideDetect.t0 = 0
end

function SideDetect.step(b)
	if CONFIG.MyColor ~= "auto" then
		if not state.sideLocked then applySide(CONFIG.MyColor) end
		return true
	end
	if state.sideLocked then return true end

	-- ưu tiên đọc màu từ module client của game (chính xác nhất)
	local c = GameAPI.myColor()
	if c then
		state.sideProvisional = false
		applySide(c)
		return true
	end

	-- Đọc hướng bàn từ nhãn toạ độ (File ở góc dưới-trái): "a" = Trắng dưới,
	-- "h" = bàn xoay (Đen dưới). Game luôn đặt quân ta ở phía dưới.
	local flip = GameAPI.coordsFlip()
	if flip ~= nil then
		setFlip(flip)
		state.sideProvisional = false
		state.sideLocked = flip and "black" or "white"
		log("Phe (coords):", state.sideLocked, "| BoardFlip:", tostring(flip))
		return true
	end

	local h = boardHash(b, nil)
	if not SideDetect.started then
		SideDetect.started = true
		SideDetect.base = {}
		for i = 1, 64 do SideDetect.base[i] = b[i] end
		SideDetect.t0 = os.clock()
		setStatus("Đang xác định phe (chờ đối thủ đi)…")
		return false
	end

	if h ~= boardHash(SideDetect.base, nil) then
		local fromIdx = nil
		for i = 1, 64 do
			if SideDetect.base[i] ~= 0 and SideDetect.base[i] ~= b[i] then
				fromIdx = i
				break
			end
		end
		local whiteIsTop = fromIdx and rankOf(fromIdx) >= 4
		state.sideProvisional = false
		applySide(whiteIsTop and "black" or "white")
		return true
	end

	-- Không ai đi sau 7s -> có thể ta đi trước -> tạm coi là Trắng
	if os.clock() - SideDetect.t0 > 7 then
		state.sideProvisional = true
		applySide("white")
		return true
	end
	return false
end

local function applyRounded(obj, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = obj
end

local function applyStroke(obj, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color or Color3.fromRGB(70, 74, 92)
	s.Thickness = thickness or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = obj
	return s
end

local function makeLabel(parent, props)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.TextColor3 = Color3.fromRGB(220, 224, 235)
	l.Font = Enum.Font.GothamMedium
	l.TextSize = 14
	l.TextXAlignment = Enum.TextXAlignment.Left
	for k, v in pairs(props or {}) do l[k] = v end
	l.Parent = parent
	return l
end

local function makeButton(parent, props)
	local b = Instance.new("TextButton")
	b.AutoButtonColor = true
	b.BackgroundColor3 = Color3.fromRGB(38, 41, 52)
	b.BorderSizePixel = 0
	b.TextColor3 = Color3.fromRGB(225, 228, 238)
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 14
	for k, v in pairs(props or {}) do b[k] = v end
	b.Parent = parent
	applyRounded(b, 10)
	return b
end

function GUI.create()
	local parentGui = LP:FindFirstChild("PlayerGui")
	local sg = Instance.new("ScreenGui")
	sg.Name = "ChessAutoUI"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.DisplayOrder = 999

	-- cố gắng bảo vệ GUI khỏi bị detect
	pcall(function() if syn and syn.protect_gui then syn.protect_gui(sg) end end)
	pcall(function() if protect_gui then protect_gui(sg) end end)
	pcall(function() sg.Parent = gethui() end)
	if not sg.Parent then sg.Parent = parentGui end

	local screen = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(720, 1280)
	local w = clamp(math.floor(screen.X * 0.62), 250, 320)
	local hNormal = 252
	local hExpanded = 412
	local h = hNormal

	local main = Instance.new("Frame")
	main.Name = "Main"
	main.Size = UDim2.fromOffset(w, h)
	main.Position = UDim2.new(1, -(w + 12), 0, 84)
	main.BackgroundColor3 = Color3.fromRGB(22, 24, 31)
	main.BorderSizePixel = 0
	main.ClipsDescendants = true
	main.Parent = sg
	applyRounded(main, 16)
	applyStroke(main, Color3.fromRGB(58, 62, 78), 1)
	state.main = main

	-- bóng mờ phía sau
	local shadow = Instance.new("Frame")
	shadow.Size = UDim2.new(1, 8, 1, 8)
	shadow.Position = UDim2.fromOffset(-4, 2)
	shadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	shadow.BackgroundTransparency = 0.55
	shadow.BorderSizePixel = 0
	shadow.ZIndex = 0
	shadow.Parent = main
	applyRounded(shadow, 18)

	-- header
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 46)
	header.BackgroundTransparency = 1
	header.Parent = main

	local title = makeLabel(header, {
		Text = "♟  Chess Auto",
		TextSize = 16,
		Font = Enum.Font.GothamBold,
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -80, 1, 0),
	})

	local minBtn = makeButton(header, {
		Text = "–",
		TextSize = 18,
		Size = UDim2.fromOffset(30, 30),
		Position = UDim2.new(1, -70, 0.5, -15),
		BackgroundColor3 = Color3.fromRGB(34, 37, 47),
	})
	minBtn.TextColor3 = Color3.fromRGB(200, 205, 220)

	local closeBtn = makeButton(header, {
		Text = "×",
		TextSize = 18,
		Size = UDim2.fromOffset(30, 30),
		Position = UDim2.new(1, -36, 0.5, -15),
		BackgroundColor3 = Color3.fromRGB(34, 37, 47),
	})
	closeBtn.TextColor3 = Color3.fromRGB(200, 205, 220)

	-- body
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.new(1, -24, 1, -58)
	body.Position = UDim2.fromOffset(12, 50)
	body.BackgroundTransparency = 1
	body.Parent = main
	state.body = body

	-- toggle chính
	local toggle = makeButton(body, {
		Text = "Auto Play Chess",
		TextSize = 15,
		Font = Enum.Font.GothamBold,
		Size = UDim2.new(1, 0, 0, 44),
		Position = UDim2.fromOffset(0, 0),
		BackgroundColor3 = Color3.fromRGB(45, 48, 60),
	})
	toggle.TextColor3 = Color3.fromRGB(215, 220, 232)
	state.toggleBtn = toggle

	-- đồng bộ màu toggle với trạng thái thực (kể cả khi auto tự dừng do lỗi)
	task.spawn(function()
		while sg.Parent do
			if state.running then
				toggle.BackgroundColor3 = Color3.fromRGB(38, 160, 92)
				toggle.TextColor3 = Color3.fromRGB(240, 255, 246)
			else
				toggle.BackgroundColor3 = Color3.fromRGB(45, 48, 60)
				toggle.TextColor3 = Color3.fromRGB(215, 220, 232)
			end
			task.wait(0.5)
		end
	end)

	-- hàng cấu hình
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 30)
	row.Position = UDim2.fromOffset(0, 54)
	row.BackgroundTransparency = 1
	row.Parent = body

	local delayBtn = makeButton(row, {
		Text = "Delay 1.5–2.5s",
		TextSize = 11,
		Size = UDim2.new(0.34, -3, 1, 0),
		Position = UDim2.fromOffset(0, 0),
		BackgroundColor3 = Color3.fromRGB(32, 35, 44),
	})
	delayBtn.TextColor3 = Color3.fromRGB(175, 182, 200)

	local depthBtn = makeButton(row, {
		Text = "Depth " .. CONFIG.Depth,
		TextSize = 11,
		Size = UDim2.new(0.33, -3, 1, 0),
		Position = UDim2.new(0.34, 0, 0, 0),
		BackgroundColor3 = Color3.fromRGB(32, 35, 44),
	})
	depthBtn.TextColor3 = Color3.fromRGB(175, 182, 200)

	local sideBtn = makeButton(row, {
		Text = "Phe: Auto",
		TextSize = 11,
		Size = UDim2.new(0.33, -3, 1, 0),
		Position = UDim2.new(0.67, 3, 0, 0),
		BackgroundColor3 = Color3.fromRGB(32, 35, 44),
	})
	sideBtn.TextColor3 = Color3.fromRGB(175, 182, 200)

	-- status
	local status = makeLabel(body, {
		Text = "Sẵn sàng",
		TextSize = 12,
		TextWrapped = true,
		Position = UDim2.fromOffset(2, 94),
		Size = UDim2.new(1, -4, 0, 34),
		TextColor3 = Color3.fromRGB(150, 156, 172),
	})
	state.statusLabel = status

	-- debug row
	local debugBtn = makeButton(body, {
		Text = "Debug: OFF",
		TextSize = 11,
		Size = UDim2.new(0, 70, 0, 24),
		Position = UDim2.fromOffset(0, 128),
		BackgroundColor3 = Color3.fromRGB(30, 33, 42),
	})
	debugBtn.TextColor3 = Color3.fromRGB(150, 156, 172)

	local acBtn = makeButton(body, {
		Text = "AC: OFF",
		TextSize = 11,
		Size = UDim2.new(0, 70, 0, 24),
		Position = UDim2.fromOffset(76, 128),
		BackgroundColor3 = Color3.fromRGB(30, 33, 42),
	})
	acBtn.TextColor3 = Color3.fromRGB(150, 156, 172)

	local copyBtn = makeButton(body, {
		Text = "Copy Debug",
		TextSize = 11,
		Size = UDim2.new(1, -152, 0, 24),
		Position = UDim2.fromOffset(152, 128),
		BackgroundColor3 = Color3.fromRGB(30, 33, 42),
	})
	copyBtn.TextColor3 = Color3.fromRGB(150, 156, 172)

	-- panel debug (ẩn mặc định)
	local debugPanel = Instance.new("Frame")
	debugPanel.Name = "DebugPanel"
	debugPanel.Size = UDim2.new(1, 0, 0, 150)
	debugPanel.Position = UDim2.fromOffset(0, 156)
	debugPanel.BackgroundColor3 = Color3.fromRGB(16, 18, 23)
	debugPanel.BorderSizePixel = 0
	debugPanel.Visible = false
	debugPanel.Parent = body
	applyRounded(debugPanel, 10)
	applyStroke(debugPanel, Color3.fromRGB(48, 52, 66), 1)

	local dbgBox = Instance.new("TextBox")
	dbgBox.Name = "Output"
	dbgBox.Size = UDim2.new(1, -12, 1, -12)
	dbgBox.Position = UDim2.fromOffset(6, 6)
	dbgBox.BackgroundTransparency = 1
	dbgBox.TextColor3 = Color3.fromRGB(176, 214, 190)
	dbgBox.Font = Enum.Font.Code
	dbgBox.TextSize = 10
	dbgBox.TextXAlignment = Enum.TextXAlignment.Left
	dbgBox.TextYAlignment = Enum.TextYAlignment.Top
	dbgBox.TextWrapped = true
	dbgBox.MultiLine = true
	dbgBox.ClearTextOnFocus = false
	dbgBox.Text = ""
	dbgBox.Parent = debugPanel
	state.debugBox = dbgBox
	state.debugPanel = debugPanel

	-- kéo thả (chuột + cảm ứng)
	local dragging, dragStart, startPos = false, nil, nil

	local function clampPos(pos, sizeOverride)
		local vp = (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize) or Vector2.new(720, 1280)
		local absSize = sizeOverride or main.AbsoluteSize
		local x = pos.X.Offset
		local y = pos.Y.Offset
		if pos.X.Scale ~= 0 then x = pos.X.Scale * vp.X end
		if pos.Y.Scale ~= 0 then y = pos.Y.Scale * vp.Y end
		x = clamp(x, 6, math.max(6, vp.X - absSize.X - 6))
		y = clamp(y, 6, math.max(6, vp.Y - absSize.Y - 6))
		return UDim2.fromOffset(round(x), round(y))
	end

	header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = main.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			local delta = input.Position - dragStart
			local newPos = UDim2.new(
				startPos.X.Scale,
				startPos.X.Offset + delta.X,
				startPos.Y.Scale,
				startPos.Y.Offset + delta.Y
			)
			main.Position = clampPos(newPos)
		end
	end)

	-- thu nhỏ
	minBtn.MouseButton1Click:Connect(function()
		state.minimized = not state.minimized
		if state.minimized then
			TweenService:Create(main, TweenInfo.new(0.18), { Size = UDim2.fromOffset(w, 46) }):Play()
			body.Visible = false
			title.Text = "♟  Chess Auto  •  " .. (state.running and "ON" or "OFF")
		else
			TweenService:Create(main, TweenInfo.new(0.18), { Size = UDim2.fromOffset(w, h) }):Play()
			task.wait(0.05)
			body.Visible = true
			title.Text = "♟  Chess Auto"
		end
	end)

	closeBtn.MouseButton1Click:Connect(function()
		state.running = false
		sg:Destroy()
	end)

	-- toggle
	toggle.MouseButton1Click:Connect(function()
		if state.running then
			state.running = false
			toggle.BackgroundColor3 = Color3.fromRGB(45, 48, 60)
			toggle.TextColor3 = Color3.fromRGB(215, 220, 232)
			setStatus("Đã dừng")
			return
		end

		-- thử nhận diện bàn cờ, chờ UI game load nếu cần (vào trận muộn)
		local board, cnt = nil, 0
		for attempt = 1, 12 do
			if not state.adapter then
				state.adapter = Adapter.detect()
			end
			if state.adapter then
				local okRead, bb = pcall(function() return state.adapter.read() end)
				cnt = 0
				if okRead and bb then
					for i = 1, 64 do if bb[i] and bb[i] ~= 0 then cnt = cnt + 1 end end
				end
				if cnt > 0 then board = bb; break end
			end
			setStatus("Đang tìm bàn cờ… (" .. attempt .. "/12)")
			task.wait(0.5)
			state.adapter = nil
		end

		if not board or cnt == 0 then
			setStatus("Chưa thấy bàn cờ — vào ván rồi bật lại (hoặc xem Debug)")
			return
		end

		Controller.start()
		if state.running then
			local aname = state.adapter and state.adapter.name or "?"
			toggle.BackgroundColor3 = Color3.fromRGB(38, 160, 92)
			toggle.TextColor3 = Color3.fromRGB(240, 255, 246)
			setStatus("Đang tự chơi… (" .. cnt .. " quân, " .. aname .. ")")
		end
	end)

	-- delay cycle
	delayBtn.MouseButton1Click:Connect(function()
		local presets = {
			{ 1.5, 2.5, "Delay 1.5–2.5s" },
			{ 1.0, 1.8, "Delay 1–1.8s" },
			{ 2.5, 4.0, "Delay 2.5–4s" },
		}
		state.delayIdx = ((state.delayIdx or 1) % #presets) + 1
		local p = presets[state.delayIdx]
		CONFIG.MoveDelayMin, CONFIG.MoveDelayMax = p[1], p[2]
		delayBtn.Text = p[3]
	end)

	-- depth cycle
	depthBtn.MouseButton1Click:Connect(function()
		local presets = { 2, 3, 4 }
		state.depthIdx = ((state.depthIdx or 2) % #presets) + 1
		CONFIG.Depth = presets[state.depthIdx]
		depthBtn.Text = "Depth " .. CONFIG.Depth
	end)

	-- chọn phe: Auto -> Trắng -> Đen
	sideBtn.MouseButton1Click:Connect(function()
		local order = { "auto", "white", "black" }
		local label = { auto = "Auto", white = "Trắng", black = "Đen" }
		local cur = CONFIG.MyColor
		local i = 1
		for k, v in ipairs(order) do if v == cur then i = k end end
		local nextMode = order[(i % #order) + 1]
		SideDetect.setSide(nextMode)
		sideBtn.Text = "Phe: " .. label[nextMode]
		setStatus("Phe: " .. label[nextMode])
	end)

	-- debug + clipboard
	local function refreshDebug(doCopy)
		if not state.adapter then
			state.adapter = Adapter.detect()
		end
		local txt, ok = DebugTool.copy()
		if state.debugBox and state.debugBox.Parent then
			state.debugBox.Text = txt
		end
		if doCopy then
			if ok then
				setStatus("Debug đã copy vào clipboard")
			else
				setStatus("Debug hiện ở panel (executor không có setclipboard)")
			end
		end
	end

	debugBtn.MouseButton1Click:Connect(function()
		state.debugOn = not state.debugOn
		debugBtn.Text = "Debug: " .. (state.debugOn and "ON" or "OFF")
		debugBtn.BackgroundColor3 = state.debugOn
			and Color3.fromRGB(60, 90, 160) or Color3.fromRGB(30, 33, 42)
		if state.debugPanel then state.debugPanel.Visible = state.debugOn end
		h = state.debugOn and hExpanded or hNormal
		if not state.minimized then
			TweenService:Create(main, TweenInfo.new(0.18), { Size = UDim2.fromOffset(w, h) }):Play()
			task.wait(0.06)
			main.Position = clampPos(main.Position, Vector2.new(w, h))
		end
		if state.debugOn then
			refreshDebug(true)
		end
	end)

	acBtn.MouseButton1Click:Connect(function()
		local on = not Bypass.blockRemotes
		Bypass.aggressive(on)
		acBtn.Text = "AC: " .. (on and "ON" or "OFF")
		acBtn.BackgroundColor3 = on
			and Color3.fromRGB(122, 72, 40) or Color3.fromRGB(30, 33, 42)
		setStatus(on and "AC bypass mạnh: ON (có thể ảnh hưởng game)" or "AC bypass mạnh: OFF (an toàn)")
	end)

	copyBtn.MouseButton1Click:Connect(function()
		refreshDebug(true)
	end)

	_G.__ChessAutoSetStatus = function(s)
		if state.statusLabel and state.statusLabel.Parent then
			state.statusLabel.Text = s
		end
	end

	return sg
end

--==============================================================================
-- CONTROLLER
--==============================================================================
Controller = {}

-- phase: "idle" (đến lượt mình) | "waitSelf" (chờ nước mình lên bàn) | "waitOpp" (chờ đối thủ)
local phase = "idle"
local lastHash = nil
local expectedHash = nil
local expectedBoard = nil
local preMoveHash = nil
local phaseTime = 0
local selfFail = 0
local stable = 0
local cooldown = 0
local revert = 0
local settle = 0

local function mySide()
	local c = state.sideLocked
	if not c and CONFIG.MyColor ~= "auto" then c = CONFIG.MyColor end
	return c == "black" and -1 or 1
end

local function sideName(s)
	return s == 1 and "Trắng" or "Đen"
end

local function randomDelay()
	local a, b = CONFIG.MoveDelayMin, CONFIG.MoveDelayMax
	return a + math.random() * (b - a)
end

--==============================================================================
-- TURN DETECT: biết đang là lượt mình hay đối thủ
--==============================================================================
-- Nguồn 1: Session:isMyTurn() (nếu tìm được instance).
-- Nguồn 2: đồng hồ của game — đồng hồ nào đang chạy là bên đó tới lượt.
--          Người chơi luôn ở nửa dưới bàn, nên clock ở dưới = của mình.
Turn = { value = nil, last = 0, ttl = 3.0 }

local function clockSeconds(t)
	if type(t) ~= "string" then return nil end
	local m, s = t:match("^%s*(%d+):(%d%d)%s*$")
	if not m then return nil end
	return tonumber(m) * 60 + tonumber(s)
end

function Turn.findClocks()
	local pGui = LP:FindFirstChild("PlayerGui")
	local out = {}
	if not pGui then return out end
	for _, d in ipairs(pGui:GetDescendants()) do
		if d:IsA("TextLabel") and d.Visible ~= false and clockSeconds(d.Text) then
			out[#out + 1] = d
		end
	end
	return out
end

-- Bên đang được đi theo đồng hồ đang chạy. Trả về 1/-1 (theo hệ toạ độ bàn),
-- hoặc nil nếu không xác định được. `side` = màu của mình (1/-1).
function Turn.sideToMove(adapter, side)
	local clocks = Turn.findClocks()
	if #clocks < 2 then return nil end

	local root = adapter and adapter.root
	local cy = 300
	if root and root.AbsolutePosition and root.AbsoluteSize then
		cy = root.AbsolutePosition.Y + root.AbsoluteSize.Y / 2
	end

	-- chỉ xét đồng hồ gần bàn cờ (bỏ đồng hồ tổng/trang trí)
	local cand = {}
	for _, c in ipairs(clocks) do
		local y = (c.AbsolutePosition and c.AbsolutePosition.Y) or 0
		if math.abs(y - cy) < 420 then
			cand[#cand + 1] = { c = c, y = y, s = clockSeconds(c.Text) }
		end
	end
	if #cand < 2 then return nil end

	task.wait(1.15)
	for _, e in ipairs(cand) do
		local after = clockSeconds(e.c.Text)
		if e.s and after and after < e.s then
			-- đồng hồ dưới bàn = của mình, trên bàn = của đối thủ
			return (e.y > cy) and side or -side
		end
	end
	return nil
end

-- Thời gian còn lại của mình (đồng hồ dưới bàn). nil nếu không đọc được.
function Turn.myClockSeconds(adapter, side)
	local clocks = Turn.findClocks()
	if #clocks == 0 then return nil end
	local root = adapter and adapter.root
	local cy = 300
	if root and root.AbsolutePosition and root.AbsoluteSize then
		cy = root.AbsolutePosition.Y + root.AbsoluteSize.Y / 2
	end
	local best, bestD = nil, math.huge
	for _, c in ipairs(clocks) do
		local y = (c.AbsolutePosition and c.AbsolutePosition.Y) or 0
		local d = math.abs(y - cy)
		if y > cy and d < 420 and d < bestD then
			best, bestD = clockSeconds(c.Text), d
		end
	end
	return best
end

function Turn.detect(adapter)
	-- 1) API của game
	local s = GameAPI.findSession()
	if s and type(s.isMyTurn) == "function" then
		local ok, mine = pcall(s.isMyTurn, s)
		if ok and type(mine) == "boolean" then
			Turn.value = mine and "me" or "opp"
			Turn.last = os.clock()
			return Turn.value
		end
	end

	-- 2) đồng hồ (cache ngắn để khỏi chờ mỗi vòng)
	local now = os.clock()
	if Turn.value ~= nil and now - Turn.last < Turn.ttl then
		return Turn.value
	end
	Turn.last = now
	Turn.value = nil

	local t = Turn.sideToMove(adapter, mySide())
	if t ~= nil then
		Turn.value = (t == mySide()) and "me" or "opp"
		return Turn.value
	end
	return nil
end

local function cloneState(st)
	local c = {
		b = {},
		turn = st.turn,
		castle = { st.castle[1], st.castle[2], st.castle[3], st.castle[4] },
		ep = st.ep,
		half = st.half,
		full = st.full,
	}
	for i = 1, 64 do c.b[i] = st.b[i] end
	return c
end

function Controller.step()
	if cooldown > 0 then
		cooldown = cooldown - 1
		return
	end
	if not state.adapter then
		state.adapter = Adapter.detect()
	end
	local adapter = state.adapter
	if not adapter then return end

	local b, aturn = adapter.read()
	if not b then
		setStatus("Không đọc được bàn cờ")
		return
	end

	-- tự nhận màu / hướng bàn
	if not SideDetect.step(b) then return end
	if not state.adapter then
		state.adapter = Adapter.detect()
		if not state.adapter then return end
		adapter = state.adapter
		b = adapter.read()
		if not b then return end
	end

	local h = boardHash(b, nil)
	local side = mySide()
	state.turnHint = phase

	-- Đen đi sau: khi bàn còn nguyên thế xuất phát thì chờ Trắng đi trước
	if side == -1 and isStartPos(b) then
		lastHash = h
		expectedBoard = b
		phase = "waitOpp"
		if state._startMsg ~= h then
			state._startMsg = h
			setStatus("Chờ Trắng đi trước…")
		end
		return
	end

	-- Máy trạng thái dựa vào thay đổi bàn cờ (không phụ thuộc đồng hồ)
	if phase == "waitSelf" then
		if h == expectedHash then
			phase = "waitOpp"; lastHash = h; selfFail = 0
			setStatus("Đã đi — chờ đối thủ")
			return
		elseif preMoveHash and h == preMoveHash then
			-- bàn vẫn y như trước khi đi -> nước chưa lên bàn
			revert = revert + 1
			if revert >= 2 then
				selfFail = selfFail + 1
				phase = "idle"; lastHash = h; stable = 0; revert = 0
				setStatus("Nước chưa lên bàn — thử lại (" .. selfFail .. ")")
			end
			return
		elseif opponentMoved(expectedBoard, b, side) then
			-- đối thủ đã đi ngay, khỏi chờ thêm
			phase = "idle"; lastHash = h; revert = 0; stable = 0
			setStatus("Đối thủ đã đi — đến lượt mình")
		else
			-- bàn đổi nhưng chưa phải đối thủ đi (quân còn chạy) -> chờ ổn định
			revert = 0
			lastHash = h
			settle = settle + 1
			if settle >= 4 then
				-- nước mình đã lên bàn (khác biểu diễn dự kiến) -> chờ đối thủ
				expectedBoard = b
				expectedHash = h
				phase = "waitOpp"; settle = 0
				setStatus("Đã đi — chờ đối thủ")
			end
			return
		end
	end

	if phase == "waitOpp" then
		if h ~= lastHash then
			lastHash = h
			if expectedBoard == nil or opponentMoved(expectedBoard, b, side) then
				phase = "idle"; stable = 0
				setStatus("Đối thủ đã đi — đến lượt mình")
			end
		end
		return
	end

	if phase == "idle" then
		if lastHash == nil or h ~= lastHash then
			lastHash = h
			phaseTime = os.clock()
			stable = 0
			return
		end
		-- đợi bàn ổn định (2 vòng ~0.8s) trước khi phân tích
		stable = stable + 1
		if stable < 2 then return end

		-- lần đầu vào giữa ván: kiểm tra đồng hồ ai đang chạy để không đi hộ đối thủ
		if expectedBoard == nil and not isStartPos(b) and state._firstTurn == nil then
			local t = Turn.sideToMove(adapter, side)
			state._firstTurn = t or 0
			if t and t ~= side then
				expectedBoard = b
				phase = "waitOpp"; lastHash = h; stable = 0
				setStatus("Đang là lượt đối thủ — chờ…")
				return
			end
		end
	end

	local turn = side
	local st = {
		b = {},
		turn = turn,
		castle = { 0, 0, 0, 0 },
		ep = nil,
		half = 0,
		full = 1,
	}
	for i = 1, 64 do st.b[i] = b[i] end

	setStatus("Đang phân tích… (" .. sideName(turn) .. ")")

	-- thời gian còn lại của mình: giảm thời gian nghĩ khi sắp hết giờ
	local myTime = Turn.myClockSeconds(adapter, side)
	local cfg = {
		Depth = CONFIG.Depth,
		TimeLimit = CONFIG.TimeLimit,
		BlunderChance = CONFIG.BlunderChance,
		BlunderWindow = CONFIG.BlunderWindow,
		AutoQueen = CONFIG.AutoQueen,
	}
	if myTime then
		if myTime < 20 and cfg.Depth > 2 then cfg.Depth = 2 end
		if myTime < 6 then cfg.Depth = 1 end
		local budget = myTime / 40
		if budget < 0.25 then budget = 0.25 end
		if budget < cfg.TimeLimit then cfg.TimeLimit = budget end
	end

	local move, scored = Engine.bestMove(st, cfg)
	if not move then
		setStatus("Không có nước đi hợp lệ (hết cờ?)")
		return
	end

	local desc = sqName(move.from) .. "→" .. sqName(move.to)
	if move.promo then desc = desc .. "=Q" end
	setStatus("Suy nghĩ: " .. desc)

	-- delay giả lập người (co lại khi ít thời gian)
	local delay = randomDelay()
	if myTime then
		local cap = myTime / 25
		if cap < 0.3 then cap = 0.3 end
		if delay > cap then delay = cap end
	end
	local t0 = os.clock()
	while os.clock() - t0 < delay do
		if not state.running then return end
		task.wait(0.1)
	end

	-- đọc lại: bàn đổi (đối thủ đi / quân còn chạy) -> tính lại
	local b2 = adapter.read()
	if b2 and boardHash(b2, nil) ~= h then
		lastHash = boardHash(b2, nil)
		phase = "idle"
		phaseTime = os.clock()
		return
	end

	-- bàn cờ kỳ vọng sau nước đi (để xác nhận nước đã lên bàn)
	local expected = cloneState(st)
	Engine.apply(expected, move)
	expectedHash = boardHash(expected.b, nil)
	expectedBoard = expected.b
	preMoveHash = h

	local ok = adapter.play(move.from, move.to, move.promo)
	if not ok then
		-- không spam thử lại: nghỉ vài vòng
		cooldown = 6
		phase = "idle"
		stable = 0
		setStatus("Chưa đi được nước (" .. desc .. ") — thử lại…")
		return
	end

	lastHash = h
	phase = "waitSelf"
	revert = 0
	settle = 0
	phaseTime = os.clock()

	if state.debugOn and scored then
		local top = {}
		for i = 1, math.min(3, #scored) do
			local e = scored[i]
			top[#top + 1] = sqName(e.m.from) .. sqName(e.m.to) .. "(" .. e.s .. ")"
		end
		log("Top:", table.concat(top, "  "))
	end
end

function Controller.start()
	if state.running then return end
	if not state.adapter then
		setStatus("Chưa có adapter")
		return
	end
	state.running = true
	phase = "idle"
	lastHash = nil
	expectedHash = nil
	phaseTime = os.clock()
	selfFail = 0
	stable = 0
	cooldown = 0
	revert = 0
	settle = 0
	expectedBoard = nil
	preMoveHash = nil
	state._firstTurn = nil
	state.sideLocked = nil
	state.sideProvisional = false
	state.adapter = nil
	state._awaitBoard = nil
	state._playedAt = 0
	state._oppHash = nil
	SideDetect.reset()
	-- mỗi ván mới game tạo instance Session/BoardView mới -> quét lại
	GameAPI._sess = nil
	GameAPI._bv = nil
	GameAPI._sessMiss = nil
	GameAPI._bvMiss = nil
	Turn.value = nil
	Turn.last = 0

	task.spawn(function()
		while state.running do
			local ok, err = pcall(Controller.step)
			if not ok then
				setStatus("Lỗi: " .. tostring(err))
				log("step error:", err)
			end
			task.wait(0.4)
		end
	end)
end

--==============================================================================
-- INIT
--==============================================================================
local function init()
	math.randomseed(os.time())

	Bypass.init()

	state.adapter = Adapter.detect()
	if state.adapter then
		log("Adapter:", state.adapter.name)
	else
		log("Không nhận diện được bàn cờ — bật Debug và kiểm tra CONFIG")
	end

	GUI.create()

	if state.adapter then
		setStatus("Sẵn sàng • " .. state.adapter.name)
	else
		setStatus("Không tìm thấy bàn cờ (xem Debug)")
	end

	-- auto start nếu muốn: Controller.start()
end

init()

-- API công khai cho người dùng nâng cao / debug trong executor console:
--   ChessAuto.Config.Depth = 4
--   ChessAuto.Controller.start()
--   ChessAuto.state.adapter
_G.ChessAuto = {
	Config = CONFIG,
	Engine = Engine,
	Adapter = Adapter,
	Controller = Controller,
	Bypass = Bypass,
	Debug = DebugTool,
	GameAPI = GameAPI,
	Side = SideDetect,
	Turn = Turn,
	state = state,
}
