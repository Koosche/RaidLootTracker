--[[============================================================
    RaidLootTracker v2.2.0
    Author: Koosche
    MS > OS > Tmog +1 System
    Bronzebeard Ascension (WotLK 3.3.5a)

    /rlt          - Toggle window
    /rlt cancel   - Cancel session / stop timer
    /rlt test     - Load test data
    /rlt help     - All commands
============================================================--]]

local ADDON_NAME = "RaidLootTracker"
local VERSION    = "2.2.0"

local DB_DEFAULTS = {
    plusOnes    = {},
    lootLog     = {},
    autoLoot    = true,
    autoTrade   = true,
    mlMode      = true,
    rollTimer   = 20,
    channel     = "RAID",
    version     = VERSION,
    windowPos   = { x = nil, y = nil },
}

local RLT = {
    db             = nil,
    session        = nil,
    waitingForItem = false,
    timerActive    = false,
    timerRemaining = 0,
    pendingTrades  = {},
    sessionClosed  = false,  -- true after timer runs out; blocks ML Mode re-trigger until resolved/cancelled
    lastItemLink   = nil,   -- prevents same link restarting a session immediately
    lastItemTime   = 0,     -- GetTime() when last session was started
}

local UI = {}

-- ============================================================
-- COLOURS (black/grey scheme)
-- ============================================================
local C = {
    prefix = "|cffbbbbbb[RLT]|r",
    gold   = "|cffffd700",
    green  = "|cff44ff44",
    red    = "|cffff5555",
    orange = "|cffff9933",
    blue   = "|cffaabbff",
    grey   = "|cffaaaaaa",
    reset  = "|r",
    ui = {
        bg        = { 0.10, 0.10, 0.10 },
        bgMid     = { 0.15, 0.15, 0.15 },
        bgLight   = { 0.20, 0.20, 0.20 },
        bgRow1    = { 0.11, 0.11, 0.11 },
        bgRow2    = { 0.16, 0.16, 0.16 },
        border    = { 0.32, 0.32, 0.32 },
        accent    = { 0.78, 0.78, 0.78 },
        gold      = { 1.00, 0.85, 0.00 },
        green     = { 0.28, 0.92, 0.42 },
        red       = { 0.92, 0.28, 0.28 },
        orange    = { 1.00, 0.60, 0.15 },
        text      = { 1.00, 1.00, 1.00 },
        dim       = { 0.58, 0.58, 0.58 },
        winner    = { 1.00, 0.85, 0.00 },
        timerGood = { 0.28, 0.88, 0.40 },
        timerWarn = { 1.00, 0.60, 0.15 },
        timerBad  = { 0.92, 0.28, 0.28 },
    }
}

local function Colorize(c,t) return c..t..C.reset end
local function Print(m)    DEFAULT_CHAT_FRAME:AddMessage(C.prefix.." "..tostring(m)) end
local function PrintErr(m) DEFAULT_CHAT_FRAME:AddMessage(C.prefix.." "..Colorize(C.red,tostring(m))) end

-- ============================================================
-- NAME / DB HELPERS
-- ============================================================
local REALM_NAME = nil
local function FullName(n)   if n:find("-",1,true) then return n end; return n.."-"..(REALM_NAME or GetRealmName()) end
local function ShortName(fn) return (fn:match("^([^%-]+)")) or fn end
local function GetPlusOnes(fn)   return RLT.db.plusOnes[fn] or 0 end
local function SetPlusOnes(fn,n) RLT.db.plusOnes[fn]=(n>=0) and n or 0 end
local function IncrPlusOnes(fn)  RLT.db.plusOnes[fn]=(RLT.db.plusOnes[fn] or 0)+1 end

local function Announce(msg)
    if IsInRaid()      then SendChatMessage(msg,RLT.db.channel)
    elseif IsInGroup() then SendChatMessage(msg,"PARTY")
    else Print(msg) end
end

-- Show big centered raid-warning-style text locally (only you see this)
local RLT_RaidWarnColor = {r=1, g=0.2, b=0.2}
local function LocalRaidWarn(msg)
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, msg, RLT_RaidWarnColor)
    end
end

-- Announce to raid AND flash locally as big warning text
local function AnnounceWarn(msg)
    Announce(msg)
    LocalRaidWarn(msg)
end

-- ============================================================
-- ROLL LOGIC
-- ============================================================
local function NewSession(itemLink,itemCount)
    return { itemLink=itemLink, itemName=itemLink:match("%[(.-)%]") or itemLink,
             itemCount=itemCount or 1, rolls={} }
end

local function SortedRollers(session)
    local ms,os,tmog={},{},{}
    for fn,data in pairs(session.rolls) do
        local e={fullName=fn,short=ShortName(fn),raw=data.raw,rollType=data.rollType,
                 plusOnes=(data.rollType=="MS") and GetPlusOnes(fn) or 0}
        if data.rollType=="MS" then ms[#ms+1]=e
        elseif data.rollType=="OS" then os[#os+1]=e
        else tmog[#tmog+1]=e end
    end
    table.sort(ms,function(a,b) if a.plusOnes~=b.plusOnes then return a.plusOnes<b.plusOnes end; return a.raw>b.raw end)
    table.sort(os,   function(a,b) return a.raw>b.raw end)
    table.sort(tmog, function(a,b) return a.raw>b.raw end)
    local sorted={}
    for _,e in ipairs(ms)   do sorted[#sorted+1]=e end
    for _,e in ipairs(os)   do sorted[#sorted+1]=e end
    for _,e in ipairs(tmog) do sorted[#sorted+1]=e end
    return sorted
end

local function ResolveSession(session)
    local sorted = SortedRollers(session)
    local count = session.itemCount
    local link = session.itemLink
    RLT.timerActive = false
    RLT.timerRemaining = 0
    
    if #sorted == 0 then 
        Announce("[RLT] No rolls for "..link.." -- no winners.")
        return {} 
    end

    Announce(string.format("[RLT] Results for %s (%d available):", link, count))
    
    -- 1. COUNT MAIN SPEC ROLLERS TO CHECK FOR CONTEST
    local msRollerCount = 0
    for _, e in ipairs(sorted) do
        if e.rollType == "MS" then
            msRollerCount = msRollerCount + 1
        end
    end

-- Updated winner logic to skip +1 for uncontested rolls 
    local winners = {}
    RLT.pendingTrades = {}
    
    for i = 1, math.min(count, #sorted) do
        local e = sorted[i]
        winners[#winners+1] = e
        
        if e.rollType == "MS" then
            -- COUNT MS ROLLERS: Check if more than 1 person rolled MS
            local msCount = 0
            for _, roller in ipairs(sorted) do
                if roller.rollType == "MS" then msCount = msCount + 1 end
            end

            -- Only award +1 if there was competition 
            if msCount > 1 then
                IncrPlusOnes(e.fullName)
                Announce("[RLT] "..e.short.." wins "..link.." (MS) -- now +"..GetPlusOnes(e.fullName))
            else
                Announce("[RLT] "..e.short.." wins "..link.." (Uncontested MS) -- no +1 applied.")
            end
        elseif e.rollType == "OS" then
            Announce("[RLT] "..e.short.." wins "..link.." (OS)")
        else
            Announce("[RLT] "..e.short.." wins "..link.." (Tmog -- no +1)")
        end
        RLT.pendingTrades[e.short:lower()] = link
    end

    -- Save to loot log
    if #winners > 0 then
        local entry = {
            date     = date("%m/%d %H:%M"),
            itemName = session.itemName,
            item     = session.itemLink,
            winners  = {},
        }
        for _, w in ipairs(winners) do
            entry.winners[#entry.winners+1] = { name=w.fullName, rollType=w.rollType }
        end
        RLT.db.lootLog[#RLT.db.lootLog+1] = entry
    end

    return winners
end

local function StartSession(itemLink,itemCount)
    if RLT.session then return end
    -- Prevent the same link from immediately restarting (e.g. WoW re-firing the chat event)
    local now=GetTime()
    if itemLink==RLT.lastItemLink and (now-RLT.lastItemTime)<5 then return end
    RLT.lastItemLink=itemLink
    RLT.lastItemTime=now
    RLT.session=NewSession(itemLink,itemCount or 1)
    RLT.waitingForItem=false
    RLT.timerRemaining=RLT.db.rollTimer
    RLT.timerActive=true
    Announce(string.format("[RLT] Rolling for %s -- %d available -- %ds to roll",
        itemLink,RLT.session.itemCount,RLT.db.rollTimer))
    Announce("[RLT] MS: /roll 100   OS: /roll 99   Tmog: /roll 98   (MS>OS>Tmog priority; OS/Tmog get no +1)")
    LocalRaidWarn("Roll: " .. (RLT.session.itemName or itemLink) .. " -- " .. RLT.db.rollTimer .. "s")
    if UI and UI.main then 
        UI.main:Show()
        if UI.SelectTab then UI.SelectTab(1) end
        if UI.Refresh then UI.Refresh() end 
    end
end

-- ============================================================
-- UI HELPERS
-- ============================================================
local function BgTex(parent,r,g,b,a,layer)
    local t=parent:CreateTexture(nil,layer or "BACKGROUND"); t:SetColorTexture(r,g,b,a or 1); return t
end

local function MakeButton(parent,label,w,h,r,g,b)
    r=r or C.ui.accent[1]; g=g or C.ui.accent[2]; b=b or C.ui.accent[3]
    local btn=CreateFrame("Button",nil,parent); btn:SetSize(w,h)
    local border=BgTex(btn,r,g,b,0.70,"BACKGROUND"); border:SetAllPoints(); btn.border=border
    local fill=BgTex(btn,r*0.18,g*0.18,b*0.18,1,"ARTWORK")
    fill:SetPoint("TOPLEFT",1,-1); fill:SetPoint("BOTTOMRIGHT",-1,1); btn.fill=fill
    local lbl=btn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    lbl:SetAllPoints(); lbl:SetJustifyH("CENTER"); lbl:SetText(label); lbl:SetTextColor(r,g,b,1); btn.label=lbl
    btn:SetScript("OnEnter",function(s)
        s.fill:SetColorTexture(r*0.35,g*0.35,b*0.35,1)
        s.border:SetColorTexture(r,g,b,1); s.label:SetTextColor(1,1,1,1) end)
    btn:SetScript("OnLeave",function(s)
        s.fill:SetColorTexture(r*0.18,g*0.18,b*0.18,1)
        s.border:SetColorTexture(r,g,b,0.70); s.label:SetTextColor(r,g,b,1) end)
    return btn
end

local function HDivider(parent,yOff,padX)
    padX=padX or 4
    local t=BgTex(parent,0.28,0.28,0.28,1,"ARTWORK"); t:SetHeight(1)
    t:SetPoint("TOPLEFT",parent,"TOPLEFT",padX,yOff); t:SetPoint("TOPRIGHT",parent,"TOPRIGHT",-padX,yOff); return t
end

local function ColHeader(parent,text,x,yOff,w,align)
    local fs=parent:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    fs:SetPoint("TOPLEFT",parent,"TOPLEFT",x,yOff); fs:SetWidth(w); fs:SetJustifyH(align or "LEFT")
    fs:SetTextColor(C.ui.dim[1],C.ui.dim[2],C.ui.dim[3]); fs:SetText(text); return fs
end

-- ============================================================
-- MAIN WINDOW
-- ============================================================
local UI={}
local WIN_W,WIN_H=460,560
local TAB_H=28

local function BuildUI()
    local f=CreateFrame("Frame","RLTMainFrame",UIParent,"BackdropTemplate")
    f:SetSize(WIN_W,WIN_H); f:SetFrameStrata("MEDIUM"); f:SetFrameLevel(10)
    f:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",edgeFile="Interface\\Buttons\\WHITE8X8",edgeSize=1})
    f:SetBackdropColor(C.ui.bg[1],C.ui.bg[2],C.ui.bg[3],0.97)
    f:SetBackdropBorderColor(C.ui.border[1],C.ui.border[2],C.ui.border[3],1)
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart",f.StartMoving)
    f:SetScript("OnDragStop",function(self)
        self:StopMovingOrSizing()
        local s=self:GetEffectiveScale()
        RLT.db.windowPos.x=self:GetLeft()*s; RLT.db.windowPos.y=self:GetTop()*s
    end)
    f:Hide(); UI.main=f

    -- Title bar
    local titleBg=BgTex(f,C.ui.bgMid[1],C.ui.bgMid[2],C.ui.bgMid[3],1,"ARTWORK")
    titleBg:SetHeight(34); titleBg:SetPoint("TOPLEFT",1,-1); titleBg:SetPoint("TOPRIGHT",-1,-1)
    local topLine=BgTex(f,C.ui.border[1],C.ui.border[2],C.ui.border[3],1,"OVERLAY")
    topLine:SetHeight(1); topLine:SetPoint("TOPLEFT",1,-35); topLine:SetPoint("TOPRIGHT",-1,-35)
    local titleFS=f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    titleFS:SetPoint("LEFT",f,"LEFT",12,0); titleFS:SetPoint("TOP",f,"TOP",0,-16)
    titleFS:SetText("RaidLootTracker"); titleFS:SetTextColor(1,1,1,1)
    local verFS=f:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    verFS:SetPoint("LEFT",titleFS,"RIGHT",8,-1); verFS:SetText("|cff555555v"..VERSION.."|r")
    local closeBtn=CreateFrame("Button",nil,f,"UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT",f,"TOPRIGHT",-2,-2); closeBtn:SetSize(28,28)
    closeBtn:SetScript("OnClick",function() f:Hide() end)

    -- Tabs
    local TAB_NAMES={"Rolls","Standings","Log","Settings"}
    local tabs,tabPanels={},{}
    local tabW=(WIN_W-2)/#TAB_NAMES

    local function SelectTab(idx)
        for i,tb in ipairs(tabs) do
            local active=(i==idx)
            if active then
                tb.fill:SetColorTexture(C.ui.bgLight[1],C.ui.bgLight[2],C.ui.bgLight[3],1)
                tb.line:SetColorTexture(C.ui.accent[1],C.ui.accent[2],C.ui.accent[3],1)
                tb.lbl:SetTextColor(1,1,1,1); tabPanels[i]:Show()
            else
                tb.fill:SetColorTexture(C.ui.bgMid[1],C.ui.bgMid[2],C.ui.bgMid[3],1)
                tb.line:SetColorTexture(C.ui.border[1],C.ui.border[2],C.ui.border[3],0.5)
                tb.lbl:SetTextColor(C.ui.dim[1],C.ui.dim[2],C.ui.dim[3]); tabPanels[i]:Hide()
            end
        end
        UI.activeTab=idx
    end
    UI.SelectTab=SelectTab

    for i,name in ipairs(TAB_NAMES) do
        local btn=CreateFrame("Button",nil,f); btn:SetSize(tabW,TAB_H)
        btn:SetPoint("TOPLEFT",f,"TOPLEFT",1+(i-1)*tabW,-36)
        local fill=BgTex(btn,C.ui.bgMid[1],C.ui.bgMid[2],C.ui.bgMid[3],1,"BACKGROUND"); fill:SetAllPoints(); btn.fill=fill
        local line=BgTex(btn,C.ui.border[1],C.ui.border[2],C.ui.border[3],0.5,"OVERLAY")
        line:SetHeight(2); line:SetPoint("BOTTOMLEFT"); line:SetPoint("BOTTOMRIGHT"); btn.line=line
        local lbl=btn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); lbl:SetAllPoints(); lbl:SetJustifyH("CENTER")
        lbl:SetText(name); lbl:SetTextColor(C.ui.dim[1],C.ui.dim[2],C.ui.dim[3]); btn.lbl=lbl
        local idx=i
        btn:SetScript("OnClick",function() SelectTab(idx) end)
        btn:SetScript("OnEnter",function(s) if UI.activeTab~=idx then s.fill:SetColorTexture(C.ui.bgLight[1],C.ui.bgLight[2],C.ui.bgLight[3],1) end end)
        btn:SetScript("OnLeave",function(s) if UI.activeTab~=idx then s.fill:SetColorTexture(C.ui.bgMid[1],C.ui.bgMid[2],C.ui.bgMid[3],1) end end)
        tabs[i]=btn
        local panel=CreateFrame("Frame",nil,f,"BackdropTemplate")
        panel:SetPoint("TOPLEFT",f,"TOPLEFT",1,-(36+TAB_H)); panel:SetPoint("BOTTOMRIGHT",f,"BOTTOMRIGHT",-1,1)
        panel:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8"})
        panel:SetBackdropColor(C.ui.bg[1],C.ui.bg[2],C.ui.bg[3],1)
        panel:SetFrameLevel(f:GetFrameLevel()+2); panel:Hide(); tabPanels[i]=panel
    end
    UI.tabPanels=tabPanels

    -- ==========================================================
    -- TAB 1: ROLLS
    -- ==========================================================
    local rp=tabPanels[1]

    -- Session header
    local rHdrBg=BgTex(rp,C.ui.bgMid[1],C.ui.bgMid[2],C.ui.bgMid[3],1,"ARTWORK")
    rHdrBg:SetHeight(80); rHdrBg:SetPoint("TOPLEFT",rp,"TOPLEFT",4,-4); rHdrBg:SetPoint("TOPRIGHT",rp,"TOPRIGHT",-4,-4)

    local rItemName=rp:CreateFontString(nil,"OVERLAY","GameFontNormal")
    rItemName:SetPoint("TOPLEFT",rp,"TOPLEFT",12,-10); rItemName:SetWidth(310); rItemName:SetJustifyH("LEFT")
    rItemName:SetText("|cff666666No active session|r"); UI.sessionName=rItemName

    local rMeta=rp:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    rMeta:SetPoint("TOPLEFT",rp,"TOPLEFT",12,-26); rMeta:SetWidth(310); rMeta:SetJustifyH("LEFT")
    rMeta:SetTextColor(C.ui.dim[1],C.ui.dim[2],C.ui.dim[3]); rMeta:SetText(""); UI.sessionMeta=rMeta

    local waitLbl=rp:CreateFontString(nil,"OVERLAY","GameFontNormal")
    waitLbl:SetPoint("TOPLEFT",rp,"TOPLEFT",12,-10); waitLbl:SetWidth(340)
    waitLbl:SetText("|cffff9933Waiting -- link an item in chat to begin...|r"); waitLbl:Hide(); UI.waitingLabel=waitLbl

    -- Count stepper
    local cntLbl=rp:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    cntLbl:SetPoint("TOPLEFT",rp,"TOPLEFT",12,-44)
    cntLbl:SetTextColor(C.ui.dim[1],C.ui.dim[2],C.ui.dim[3]); cntLbl:SetText("Available:"); cntLbl:Hide(); UI.countLabel=cntLbl
    local minusBtn=MakeButton(rp," - ",22,18,C.ui.dim[1],C.ui.dim[2],C.ui.dim[3])
    minusBtn:SetPoint("TOPLEFT",rp,"TOPLEFT",80,-41); minusBtn:Hide(); UI.minusBtn=minusBtn
    local cntNum=rp:CreateFontString(nil,"OVERLAY","GameFontNormal")
    cntNum:SetPoint("LEFT",minusBtn,"RIGHT",5,0); cntNum:SetWidth(20); cntNum:SetJustifyH("CENTER")
    cntNum:SetText("1"); cntNum:SetTextColor(C.ui.gold[1],C.ui.gold[2],C.ui.gold[3]); cntNum:Hide(); UI.countNum=cntNum
    local plusBtn=MakeButton(rp," + ",22,18,C.ui.green[1],C.ui.green[2],C.ui.green[3])
    plusBtn:SetPoint("LEFT",cntNum,"RIGHT",5,0); plusBtn:Hide(); UI.plusBtn=plusBtn
    local cntHint=rp:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    cntHint:SetPoint("LEFT",plusBtn,"RIGHT",8,0); cntHint:SetTextColor(C.ui.dim[1],C.ui.dim[2],C.ui.dim[3])
    cntHint:SetText("copies dropping"); cntHint:Hide(); UI.countHint=cntHint
    minusBtn:SetScript("OnClick",function() if RLT.session then RLT.session.itemCount=math.max(1,RLT.session.itemCount-1); UI.RefreshRolls() end end)
    plusBtn:SetScript("OnClick", function() if RLT.session then RLT.session.itemCount=math.min(40,RLT.session.itemCount+1); UI.RefreshRolls() end end)

    -- Timer bar
    local timerBg=BgTex(rp,0.07,0.07,0.07,1,"ARTWORK")
    timerBg:SetHeight(12); timerBg:SetPoint("TOPLEFT",rp,"TOPLEFT",4,-66); timerBg:SetPoint("TOPRIGHT",rp,"TOPRIGHT",-4,-66)
    local timerFill=BgTex(rp,C.ui.timerGood[1],C.ui.timerGood[2],C.ui.timerGood[3],1,"OVERLAY")
    timerFill:SetHeight(12); timerFill:SetPoint("TOPLEFT",rp,"TOPLEFT",4,-66); timerFill:SetWidth(0); UI.timerFill=timerFill
    local timerText=rp:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    timerText:SetPoint("CENTER",timerBg,"CENTER",0,0); timerText:SetText(""); timerText:SetTextColor(1,1,1,1); UI.timerText=timerText

    -- ML Mode quick-toggle (top-right of Rolls tab header)
    local mlQuickBtn=MakeButton(rp,"ML: ON",68,22,C.ui.green[1],C.ui.green[2],C.ui.green[3])
    mlQuickBtn:SetPoint("TOPRIGHT",rp,"TOPRIGHT",-8,-8)
    UI.mlQuickBtn=mlQuickBtn
    function UI.RefreshMLQuick()
        if not RLT.db then return end
        if RLT.db.mlMode then
            mlQuickBtn.fill:SetColorTexture(C.ui.green[1]*0.35,C.ui.green[2]*0.35,C.ui.green[3]*0.35,1)
            mlQuickBtn.border:SetColorTexture(C.ui.green[1],C.ui.green[2],C.ui.green[3],1)
            mlQuickBtn.label:SetTextColor(1,1,1,1); mlQuickBtn.label:SetText("ML: ON")
        else
            mlQuickBtn.fill:SetColorTexture(C.ui.red[1]*0.18,C.ui.red[2]*0.18,C.ui.red[3]*0.18,1)
            mlQuickBtn.border:SetColorTexture(C.ui.red[1],C.ui.red[2],C.ui.red[3],0.70)
            mlQuickBtn.label:SetTextColor(C.ui.red[1],C.ui.red[2],C.ui.red[3]); mlQuickBtn.label:SetText("ML: OFF")
        end
    end
    mlQuickBtn:SetScript("OnClick",function()
        RLT.db.mlMode=not RLT.db.mlMode
        UI.RefreshMLQuick(); UI.RefreshMLMode(); UI.RefreshRolls()
    end)
    mlQuickBtn:SetScript("OnEnter",function(self)
        GameTooltip:SetOwner(self,"ANCHOR_BOTTOMRIGHT")
        GameTooltip:SetText("ML Mode",1,1,1)
        GameTooltip:AddLine(RLT.db.mlMode and "ON - auto-starts when you link an item" or "OFF - use /rlt roll manually",0.7,0.7,0.7)
        GameTooltip:AddLine("Click to toggle",0.5,0.5,0.5)
        GameTooltip:Show()
    end)
    mlQuickBtn:SetScript("OnLeave",function() GameTooltip:Hide() end)

    -- Roll count badge (now below ML toggle)
    local badgeBg=BgTex(rp,C.ui.bgLight[1],C.ui.bgLight[2],C.ui.bgLight[3],1,"ARTWORK")
    badgeBg:SetSize(52,36); badgeBg:SetPoint("TOPRIGHT",rp,"TOPRIGHT",-8,-34)
    local badgeNum=rp:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    badgeNum:SetAllPoints(badgeBg); badgeNum:SetJustifyH("CENTER"); badgeNum:SetJustifyV("MIDDLE")
    badgeNum:SetText("0"); badgeNum:SetTextColor(1,1,1,1); UI.rollCount=badgeNum
    local badgeLbl=rp:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    badgeLbl:SetPoint("TOP",badgeBg,"BOTTOM",0,1); badgeLbl:SetText("|cff555555rolls|r")

    HDivider(rp,-88)

    -- Column headers
    ColHeader(rp,"#",     8, -94, 22)
    ColHeader(rp,"Player",32,-94, 140)
    ColHeader(rp,"Roll",  176,-94,40,"RIGHT")
    ColHeader(rp,"Type",  222,-94,38,"CENTER")
    ColHeader(rp,"+1s",   266,-94,36,"CENTER")
    ColHeader(rp,"Status",308,-94,130,"CENTER")
    HDivider(rp,-106)

    -- Roll rows
    local NUM_ROWS=16; local rowPool={}
    for i=1,NUM_ROWS do
        local yB=-108-(i-1)*20; local alt=(i%2==0)
        local bg=BgTex(rp,alt and C.ui.bgRow2[1] or C.ui.bgRow1[1],alt and C.ui.bgRow2[2] or C.ui.bgRow1[2],alt and C.ui.bgRow2[3] or C.ui.bgRow1[3],0,"BACKGROUND")
        bg:SetHeight(19); bg:SetPoint("TOPLEFT",rp,"TOPLEFT",4,yB); bg:SetPoint("TOPRIGHT",rp,"TOPRIGHT",-4,yB)
        local function FS(x,w,align)
            local fs=rp:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
            fs:SetPoint("TOPLEFT",rp,"TOPLEFT",x,yB+2); fs:SetWidth(w); fs:SetJustifyH(align or "LEFT"); return fs
        end
        local row={bg=bg,rank=FS(8,22),name=FS(32,140),roll=FS(176,40,"RIGHT"),
                   typ=FS(222,38,"CENTER"),pens=FS(266,36,"CENTER"),status=FS(308,130,"CENTER")}
        row.rank:SetTextColor(C.ui.dim[1],C.ui.dim[2],C.ui.dim[3])
        row.name:SetTextColor(C.ui.text[1],C.ui.text[2],C.ui.text[3])
        row.roll:SetTextColor(C.ui.gold[1],C.ui.gold[2],C.ui.gold[3])
        row.typ:SetTextColor(C.ui.text[1],C.ui.text[2],C.ui.text[3])
        row.pens:SetTextColor(C.ui.orange[1],C.ui.orange[2],C.ui.orange[3])
        row.status:SetTextColor(C.ui.dim[1],C.ui.dim[2],C.ui.dim[3])
        for k,v in pairs(row) do if k~="bg" then v:Hide() end end
        rowPool[i]=row
    end
    UI.rowPool=rowPool

    -- Bottom buttons
    local resolveBtn=MakeButton(rp,"Resolve",120,26,C.ui.green[1],C.ui.green[2],C.ui.green[3])
    resolveBtn:SetPoint("BOTTOMLEFT",rp,"BOTTOMLEFT",8,6)
    local cancelBtn=MakeButton(rp,"Cancel",96,26,C.ui.red[1],C.ui.red[2],C.ui.red[3])
    cancelBtn:SetPoint("LEFT",resolveBtn,"RIGHT",4,0)
    local refreshBtn=MakeButton(rp,"Refresh",96,26,C.ui.accent[1],C.ui.accent[2],C.ui.accent[3])
    refreshBtn:SetPoint("LEFT",cancelBtn,"RIGHT",4,0)
    local testBtn=MakeButton(rp,"Test Mode",110,26,C.ui.orange[1],C.ui.orange[2],C.ui.orange[3])
    testBtn:SetPoint("BOTTOMRIGHT",rp,"BOTTOMRIGHT",-8,6)

    resolveBtn:SetScript("OnClick",function()
        if not RLT.session then PrintErr("No active session."); return end
        local s=RLT.session; RLT.session=nil; RLT.sessionClosed=false; ResolveSession(s); UI.Refresh()
    end)
    cancelBtn:SetScript("OnClick",function()
        if RLT.waitingForItem then RLT.waitingForItem=false; Print("Cancelled."); UI.Refresh(); return end
        if not RLT.session then PrintErr("No active session."); return end
        RLT.timerActive=false; RLT.timerRemaining=0
        Print("Cancelled: "..RLT.session.itemLink); RLT.sessionClosed=false; RLT.session=nil; UI.Refresh()
    end)
    refreshBtn:SetScript("OnClick",function() UI.Refresh() end)
    testBtn:SetScript("OnClick",function()
        if RLT.session then PrintErr("Cancel current session first."); return end
        local realm=REALM_NAME or GetRealmName()
        RLT.session=NewSession("[Shadowmourne]",2)
        local td={{name="PlayerA",roll=87,rollType="MS",plusOnes=2},
                  {name="PlayerB",roll=94,rollType="MS",plusOnes=1},
                  {name="PlayerC",roll=42,rollType="MS",plusOnes=0},
                  {name="PlayerD",roll=71,rollType="OS",plusOnes=0},
                  {name="TPlayerE",roll=55,rollType="MS",plusOnes=0},
                  {name="PlayerF",roll=99,rollType="MS",plusOnes=1}}
        for _,p in ipairs(td) do
            local fn=p.name.."-"..realm
            RLT.session.rolls[fn]={raw=p.roll,rollType=p.rollType}
            if p.plusOnes>0 then RLT.db.plusOnes[fn]=p.plusOnes end
        end
        RLT.timerRemaining=RLT.db.rollTimer; RLT.timerActive=true
        Print(Colorize(C.orange,"[TEST]").." 6 fake players, 30s timer.")
        UI.Refresh(); SelectTab(1)
    end)

    function UI.RefreshRolls()
        local hasSession=RLT.session~=nil
        local isWaiting=RLT.waitingForItem
        UI.waitingLabel:SetShown(isWaiting)
        rItemName:SetShown(not isWaiting)
        rMeta:SetShown(hasSession and not isWaiting)
        UI.countLabel:SetShown(hasSession); UI.minusBtn:SetShown(hasSession)
        UI.countNum:SetShown(hasSession); UI.plusBtn:SetShown(hasSession); UI.countHint:SetShown(hasSession)

        if not hasSession then
            if not isWaiting then
                if RLT.sessionClosed then
                rItemName:SetText("|cffff9933Roll closed -- click Resolve to finalize|r")
            elseif RLT.db and RLT.db.mlMode then
                rItemName:SetText("|cff666666ML Mode ON -- link an item in chat to begin|r")
            else
                rItemName:SetText("|cff666666No active session -- /rlt roll to begin|r")
            end
            end
            rMeta:SetText(""); badgeNum:SetText("0")
            timerFill:SetWidth(0); timerText:SetText("")
            for _,row in ipairs(rowPool) do
                row.bg:SetColorTexture(0,0,0,0)
                for k,v in pairs(row) do if k~="bg" then v:Hide() end end
            end
            return
        end

        UI.countNum:SetText(tostring(RLT.session.itemCount))

        -- Timer bar
        local totalSec=RLT.db.rollTimer; local rem=RLT.timerRemaining
        if RLT.timerActive and totalSec>0 then
            local pct=math.max(0,rem/totalSec)
            timerFill:SetWidth(math.max(0,math.floor((WIN_W-12)*pct)))
            if pct>0.5 then timerFill:SetColorTexture(C.ui.timerGood[1],C.ui.timerGood[2],C.ui.timerGood[3],1)
            elseif pct>0.2 then timerFill:SetColorTexture(C.ui.timerWarn[1],C.ui.timerWarn[2],C.ui.timerWarn[3],1)
            else timerFill:SetColorTexture(C.ui.timerBad[1],C.ui.timerBad[2],C.ui.timerBad[3],1) end
            timerText:SetText(math.ceil(rem).."s")
        else timerFill:SetWidth(0); timerText:SetText("") end

        local sorted=SortedRollers(RLT.session)
        local total=0; for _ in pairs(RLT.session.rolls) do total=total+1 end
        rItemName:SetText(RLT.session.itemLink)
        rMeta:SetText(total.." roller"..(total==1 and "" or "s")
            .."     |cff44ff44MS: /roll 100|r   |cffaabbffOS: /roll 99|r   |cffaaaaaaT: /roll 98|r")
        badgeNum:SetText(tostring(total))

        for i,row in ipairs(rowPool) do
            local e=sorted[i]
            if e then
                local isWin=(i<=RLT.session.itemCount); local alt=(i%2==0)
                if isWin then row.bg:SetColorTexture(0.24,0.19,0.00,1)
                elseif alt then row.bg:SetColorTexture(C.ui.bgRow2[1],C.ui.bgRow2[2],C.ui.bgRow2[3],1)
                else row.bg:SetColorTexture(C.ui.bgRow1[1],C.ui.bgRow1[2],C.ui.bgRow1[3],1) end
                row.rank:SetText(tostring(i))
                row.rank:SetTextColor(isWin and C.ui.gold[1] or C.ui.dim[1],isWin and C.ui.gold[2] or C.ui.dim[2],isWin and C.ui.gold[3] or C.ui.dim[3])
                row.name:SetText(e.short)
                row.name:SetTextColor(isWin and 1 or C.ui.text[1],isWin and 1 or C.ui.text[2],isWin and 1 or C.ui.text[3])
                row.roll:SetText(tostring(e.raw))
                local typStr
                if e.rollType=="MS" then typStr="|cff44ff44MS|r"
                elseif e.rollType=="OS" then typStr="|cffaabbffOS|r"
                else typStr="|cffaaaaaa Tmog|r" end
                row.typ:SetText(typStr)
                row.pens:SetText((e.rollType=="MS" and e.plusOnes>0) and ("|cffff9933+"..e.plusOnes.."|r") or "|cff333333-|r")
                row.status:SetText(isWin and "|cffffd700WINNER|r" or (e.rollType=="OS" and "|cffaabbffOS|r" or "|cff333333-|r"))
                for k,v in pairs(row) do if k~="bg" then v:Show() end end
            else
                row.bg:SetColorTexture(0,0,0,0)
                for k,v in pairs(row) do if k~="bg" then v:Hide() end end
            end
        end
    end

    -- ==========================================================
    -- TAB 2: STANDINGS
    -- ==========================================================
    local sp=tabPanels[2]
    local spLbl=sp:CreateFontString(nil,"OVERLAY","GameFontNormal"); spLbl:SetPoint("TOPLEFT",sp,"TOPLEFT",10,-10)
    spLbl:SetText("+1 Standings"); spLbl:SetTextColor(1,1,1,1)
    local spReset=MakeButton(sp,"Reset All +1s",120,22,C.ui.red[1],C.ui.red[2],C.ui.red[3])
    spReset:SetPoint("TOPRIGHT",sp,"TOPRIGHT",-8,-8)
    spReset:SetScript("OnClick",function() RLT.db.plusOnes={}; UI.RefreshStandings(); Print("All +1 data wiped.") end)
    HDivider(sp,-30)
    ColHeader(sp,"Player",8,-36,190); ColHeader(sp,"+1s",202,-36,50,"CENTER"); ColHeader(sp,"Bar",258,-36,170)
    HDivider(sp,-48)
    local STAND_ROWS=19; local standRows={}
    for i=1,STAND_ROWS do
        local yB=-50-(i-1)*20; local alt=(i%2==0)
        local bg=BgTex(sp,alt and C.ui.bgRow2[1] or C.ui.bgRow1[1],alt and C.ui.bgRow2[2] or C.ui.bgRow1[2],alt and C.ui.bgRow2[3] or C.ui.bgRow1[3],0,"BACKGROUND")
        bg:SetHeight(19); bg:SetPoint("TOPLEFT",sp,"TOPLEFT",4,yB); bg:SetPoint("TOPRIGHT",sp,"TOPRIGHT",-4,yB)
        local function FS(x,w,align) local fs=sp:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); fs:SetPoint("TOPLEFT",sp,"TOPLEFT",x,yB+2); fs:SetWidth(w); fs:SetJustifyH(align or "LEFT"); return fs end
        local namFS=FS(8,190); local cntFS=FS(202,50,"CENTER")
        namFS:SetTextColor(C.ui.text[1],C.ui.text[2],C.ui.text[3]); cntFS:SetTextColor(C.ui.orange[1],C.ui.orange[2],C.ui.orange[3])
        local barBg=BgTex(sp,0.14,0.14,0.14,1,"ARTWORK"); barBg:SetHeight(8); barBg:SetWidth(170); barBg:SetPoint("TOPLEFT",sp,"TOPLEFT",258,yB-5)
        local barFill=BgTex(sp,C.ui.orange[1],C.ui.orange[2],C.ui.orange[3],1,"OVERLAY"); barFill:SetHeight(8); barFill:SetWidth(0); barFill:SetPoint("TOPLEFT",barBg,"TOPLEFT",0,0)
        for _,v in ipairs({bg,namFS,cntFS,barBg,barFill}) do v:Hide() end
        standRows[i]={bg=bg,name=namFS,count=cntFS,barBg=barBg,barFill=barFill}
    end
    local noStandLbl=sp:CreateFontString(nil,"OVERLAY","GameFontNormal"); noStandLbl:SetPoint("CENTER",sp,"CENTER",0,0)
    noStandLbl:SetText("|cff444444No +1 data yet.|r"); UI.noStandLbl=noStandLbl
    function UI.RefreshStandings()
        local list={}
        for fn,cnt in pairs(RLT.db.plusOnes) do if cnt and cnt>0 then list[#list+1]={name=fn,count=cnt} end end
        table.sort(list,function(a,b) if a.count~=b.count then return a.count>b.count end; return a.name<b.name end)
        local maxC=(list[1] and list[1].count) or 1
        noStandLbl:SetShown(#list==0)
        for i,row in ipairs(standRows) do
            local e=list[i]
            if e then
                local alt=(i%2==0)
                row.bg:SetColorTexture(alt and C.ui.bgRow2[1] or C.ui.bgRow1[1],alt and C.ui.bgRow2[2] or C.ui.bgRow1[2],alt and C.ui.bgRow2[3] or C.ui.bgRow1[3],1)
                row.name:SetText(ShortName(e.name)); row.count:SetText("+"..e.count)
                local pct=e.count/maxC; row.barFill:SetWidth(math.max(2,170*pct))
                local r=math.min(1,pct*1.5); local g=math.max(0,1-pct)
                row.barFill:SetColorTexture(r,g*0.6,0.05,1)
                for _,v in ipairs({row.bg,row.name,row.count,row.barBg,row.barFill}) do v:Show() end
            else for _,v in ipairs({row.bg,row.name,row.count,row.barBg,row.barFill}) do v:Hide() end end
        end
    end

    -- ==========================================================
    -- TAB 3: LOG
    -- ==========================================================
    local lp=tabPanels[3]
    local lpLbl=lp:CreateFontString(nil,"OVERLAY","GameFontNormal"); lpLbl:SetPoint("TOPLEFT",lp,"TOPLEFT",10,-10)
    lpLbl:SetText("Loot History"); lpLbl:SetTextColor(1,1,1,1)
    local lpClear=MakeButton(lp,"Clear Log",100,22,C.ui.red[1],C.ui.red[2],C.ui.red[3])
    lpClear:SetPoint("TOPRIGHT",lp,"TOPRIGHT",-8,-8)
    lpClear:SetScript("OnClick",function() RLT.db.lootLog={}; UI.RefreshLog(); Print("Log cleared.") end)
    HDivider(lp,-30)
    local LOG_ROWS=16; local logRows={}
    for i=1,LOG_ROWS do
        local ROW_LH=30; local yB=-33-(i-1)*ROW_LH; local alt=(i%2==0)
        local bg=BgTex(lp,alt and C.ui.bgRow2[1] or C.ui.bgRow1[1],alt and C.ui.bgRow2[2] or C.ui.bgRow1[2],alt and C.ui.bgRow2[3] or C.ui.bgRow1[3],0,"BACKGROUND")
        bg:SetHeight(ROW_LH-1); bg:SetPoint("TOPLEFT",lp,"TOPLEFT",4,yB); bg:SetPoint("TOPRIGHT",lp,"TOPRIGHT",-4,yB)
        local function FS(x,y2,w,align) local fs=lp:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); fs:SetPoint("TOPLEFT",lp,"TOPLEFT",x,yB+y2); fs:SetWidth(w); fs:SetJustifyH(align or "LEFT"); return fs end
        local dateFS=FS(8,-1,100); local itemFS=FS(112,-1,200); local winFS=FS(8,-14,420)
        dateFS:SetTextColor(C.ui.dim[1],C.ui.dim[2],C.ui.dim[3]); itemFS:SetTextColor(C.ui.gold[1],C.ui.gold[2],C.ui.gold[3]); winFS:SetTextColor(C.ui.text[1],C.ui.text[2],C.ui.text[3])
        local divLine=BgTex(lp,0.20,0.20,0.20,0.6,"ARTWORK"); divLine:SetHeight(1)
        divLine:SetPoint("BOTTOMLEFT",lp,"TOPLEFT",4,yB-ROW_LH+2); divLine:SetPoint("BOTTOMRIGHT",lp,"TOPRIGHT",-4,yB-ROW_LH+2)
        for _,v in ipairs({bg,dateFS,itemFS,winFS,divLine}) do v:Hide() end
        logRows[i]={bg=bg,date=dateFS,item=itemFS,winners=winFS,div=divLine}
    end
    local noLogLbl=lp:CreateFontString(nil,"OVERLAY","GameFontNormal"); noLogLbl:SetPoint("CENTER",lp,"CENTER",0,0)
    noLogLbl:SetText("|cff444444No loot history yet.|r"); UI.noLogLbl=noLogLbl
    function UI.RefreshLog()
        local log=RLT.db.lootLog; noLogLbl:SetShown(#log==0)
        for i=1,LOG_ROWS do
            local e=log[#log-(i-1)]; local row=logRows[i]
            if e then
                local alt=(i%2==0)
                row.bg:SetColorTexture(alt and C.ui.bgRow2[1] or C.ui.bgRow1[1],alt and C.ui.bgRow2[2] or C.ui.bgRow1[2],alt and C.ui.bgRow2[3] or C.ui.bgRow1[3],1)
                row.date:SetText(e.date or "?")
                row.item:SetText((e.item and e.item:match("%[(.-)%]")) or e.itemName or "?")
                local wns={}; for _,w in ipairs(e.winners or {}) do wns[#wns+1]=ShortName(w.name)..(w.rollType=="OS" and "(OS)" or "") end
                row.winners:SetText("-> "..(#wns>0 and table.concat(wns,", ") or "none"))
                for _,v in ipairs({row.bg,row.date,row.item,row.winners,row.div}) do v:Show() end
            else for _,v in ipairs({row.bg,row.date,row.item,row.winners,row.div}) do v:Hide() end end
        end
    end

    -- ==========================================================
    -- TAB 4: SETTINGS
    -- ==========================================================
    local setp = tabPanels[4]

    local function ActiveToggle(btn, r, g, b, on)
        if on then
            btn.fill:SetColorTexture(r*0.35,g*0.35,b*0.35,1); btn.border:SetColorTexture(r,g,b,1); btn.label:SetTextColor(1,1,1,1)
        else
            btn.fill:SetColorTexture(r*0.10,g*0.10,b*0.10,1); btn.border:SetColorTexture(r,g,b,0.30); btn.label:SetTextColor(r*0.7,g*0.7,b*0.7,1)
        end
    end

    -- Layout constants  (panel is ~430px tall after tab strip)
    local PAD   = 10
    local BTN_H = 22
    local BTN_W = 54
    local RH    = 44   -- each setting row height
    local cur   = 0    -- running y cursor (negative offset from panel top)

    local function Row(title, desc)
        local y = cur
        local bg = BgTex(setp,C.ui.bgMid[1],C.ui.bgMid[2],C.ui.bgMid[3],1,"BACKGROUND")
        bg:SetHeight(RH); bg:SetPoint("TOPLEFT",setp,"TOPLEFT",1,y); bg:SetPoint("TOPRIGHT",setp,"TOPRIGHT",-1,y)
        local t = setp:CreateFontString(nil,"OVERLAY","GameFontNormal")
        t:SetPoint("TOPLEFT",setp,"TOPLEFT",PAD,y-8); t:SetText(title); t:SetTextColor(1,1,1,1)
        local d = setp:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        d:SetPoint("TOPLEFT",setp,"TOPLEFT",PAD,y-22); d:SetWidth(WIN_W-175); d:SetJustifyH("LEFT")
        d:SetText(desc); d:SetTextColor(C.ui.dim[1],C.ui.dim[2],C.ui.dim[3])
        cur = cur - RH
        -- divider at bottom of row
        local div = BgTex(setp,0.25,0.25,0.25,1,"ARTWORK"); div:SetHeight(1)
        div:SetPoint("TOPLEFT",setp,"TOPLEFT",1,cur); div:SetPoint("TOPRIGHT",setp,"TOPRIGHT",-1,cur)
        return y  -- return top-of-row y so callers can place buttons
    end

    local function SectionHdr(label)
        local y = cur
        local bg = BgTex(setp,C.ui.bgLight[1],C.ui.bgLight[2],C.ui.bgLight[3],1,"BACKGROUND")
        bg:SetHeight(24); bg:SetPoint("TOPLEFT",setp,"TOPLEFT",1,y); bg:SetPoint("TOPRIGHT",setp,"TOPRIGHT",-1,y)
        local t = setp:CreateFontString(nil,"OVERLAY","GameFontNormal")
        t:SetPoint("TOPLEFT",setp,"TOPLEFT",PAD,y-6); t:SetText(label); t:SetTextColor(1,1,1,1)
        local div = BgTex(setp,0.28,0.28,0.28,1,"ARTWORK"); div:SetHeight(1)
        div:SetPoint("TOPLEFT",setp,"TOPLEFT",1,y-24); div:SetPoint("TOPRIGHT",setp,"TOPRIGHT",-1,y-24)
        cur = cur - 24
    end

    -- ── Settings header ───────────────────────────────────────
    SectionHdr("Settings")

    -- ── ML Mode ───────────────────────────────────────────────
    local ry1 = Row("ML Mode","Auto-start rolls when you link an item in chat.")
    local mlOffBtn = MakeButton(setp,"OFF",BTN_W,BTN_H,C.ui.red[1],C.ui.red[2],C.ui.red[3])
    local mlOnBtn  = MakeButton(setp,"ON", BTN_W,BTN_H,C.ui.green[1],C.ui.green[2],C.ui.green[3])
    mlOffBtn:SetPoint("TOPRIGHT",setp,"TOPRIGHT",-8,ry1-11)
    mlOnBtn:SetPoint("RIGHT",mlOffBtn,"LEFT",-4,0)
    UI.mlOnBtn=mlOnBtn; UI.mlOffBtn=mlOffBtn
    function UI.RefreshMLMode()
        if not RLT.db then return end
        ActiveToggle(mlOnBtn, C.ui.green[1],C.ui.green[2],C.ui.green[3],RLT.db.mlMode)
        ActiveToggle(mlOffBtn,C.ui.red[1],  C.ui.red[2],  C.ui.red[3],  not RLT.db.mlMode)
    end
    mlOnBtn:SetScript("OnClick", function() RLT.db.mlMode=true;  UI.RefreshMLMode(); UI.RefreshRolls(); if UI.RefreshMLQuick then UI.RefreshMLQuick() end end)
    mlOffBtn:SetScript("OnClick",function() RLT.db.mlMode=false; UI.RefreshMLMode(); UI.RefreshRolls(); if UI.RefreshMLQuick then UI.RefreshMLQuick() end end)

    -- ── Roll Timer ────────────────────────────────────────────
    local ry2 = Row("Roll Timer","Seconds before rolls close. Steps of 10.")
    local timerDisp = setp:CreateFontString(nil,"OVERLAY","GameFontNormal")
    timerDisp:SetPoint("TOPRIGHT",setp,"TOPRIGHT",-8,ry2-10)
    timerDisp:SetWidth(44); timerDisp:SetJustifyH("CENTER"); timerDisp:SetTextColor(C.ui.gold[1],C.ui.gold[2],C.ui.gold[3])
    UI.timerDisp=timerDisp
    local tPls=MakeButton(setp,"+",26,BTN_H,C.ui.green[1],C.ui.green[2],C.ui.green[3]); tPls:SetPoint("RIGHT",timerDisp,"LEFT",-4,0)
    local tMin=MakeButton(setp,"-",26,BTN_H,C.ui.dim[1],C.ui.dim[2],C.ui.dim[3]);       tMin:SetPoint("RIGHT",tPls,"LEFT",-4,0)
    function UI.RefreshTimerDisp() if RLT.db then timerDisp:SetText(tostring(RLT.db.rollTimer).."s") end end
    tMin:SetScript("OnClick",function() RLT.db.rollTimer=math.max(10, RLT.db.rollTimer-10); UI.RefreshTimerDisp() end)
    tPls:SetScript("OnClick",function() RLT.db.rollTimer=math.min(300,RLT.db.rollTimer+10); UI.RefreshTimerDisp() end)

    -- ── Auto-Loot ─────────────────────────────────────────────
    local ry3 = Row("Auto-Loot","Auto-loot boss corpse when you are Master Looter.")
    local alOff=MakeButton(setp,"OFF",BTN_W,BTN_H,C.ui.red[1],  C.ui.red[2],  C.ui.red[3])
    local alOn= MakeButton(setp,"ON", BTN_W,BTN_H,C.ui.green[1],C.ui.green[2],C.ui.green[3])
    alOff:SetPoint("TOPRIGHT",setp,"TOPRIGHT",-8,ry3-11)
    alOn:SetPoint("RIGHT",alOff,"LEFT",-4,0)
    UI.alOnBtn=alOn; UI.alOffBtn=alOff
    function UI.RefreshAutoLoot()
        if not RLT.db then return end
        ActiveToggle(alOn, C.ui.green[1],C.ui.green[2],C.ui.green[3],RLT.db.autoLoot)
        ActiveToggle(alOff,C.ui.red[1],  C.ui.red[2],  C.ui.red[3],  not RLT.db.autoLoot)
    end
    alOn:SetScript("OnClick", function() RLT.db.autoLoot=true;  UI.RefreshAutoLoot() end)
    alOff:SetScript("OnClick",function() RLT.db.autoLoot=false; UI.RefreshAutoLoot() end)

    -- ── Auto-Trade ────────────────────────────────────────────
    local ryAT = Row("Auto-Trade","Auto-fill trade & announce trades for roll winners.")
    local atOff=MakeButton(setp,"OFF",BTN_W,BTN_H,C.ui.red[1],  C.ui.red[2],  C.ui.red[3])
    local atOn= MakeButton(setp,"ON", BTN_W,BTN_H,C.ui.green[1],C.ui.green[2],C.ui.green[3])
    atOff:SetPoint("TOPRIGHT",setp,"TOPRIGHT",-8,ryAT-11)
    atOn:SetPoint("RIGHT",atOff,"LEFT",-4,0)
    UI.atOnBtn=atOn; UI.atOffBtn=atOff
    function UI.RefreshAutoTrade()
        if not RLT.db then return end
        ActiveToggle(atOn, C.ui.green[1],C.ui.green[2],C.ui.green[3],RLT.db.autoTrade)
        ActiveToggle(atOff,C.ui.red[1],  C.ui.red[2],  C.ui.red[3],  not RLT.db.autoTrade)
    end
    atOn:SetScript("OnClick", function() RLT.db.autoTrade=true;  UI.RefreshAutoTrade() end)
    atOff:SetScript("OnClick",function() RLT.db.autoTrade=false; UI.RefreshAutoTrade() end)

    -- ── Announce Channel ──────────────────────────────────────
    local ry4 = Row("Announce Channel","Where results are announced.")
    local chanBtns,CHANS={},{"RAID","PARTY","SAY"}
    local cRight=-8
    for i=#CHANS,1,-1 do
        local ch=CHANS[i]
        local btn=MakeButton(setp,ch,62,BTN_H,C.ui.accent[1],C.ui.accent[2],C.ui.accent[3])
        btn:SetPoint("TOPRIGHT",setp,"TOPRIGHT",cRight,ry4-11); cRight=cRight-62-4
        local cch=ch; btn:SetScript("OnClick",function() RLT.db.channel=cch; UI.RefreshChannel() end)
        chanBtns[ch]=btn
    end
    UI.chanBtns=chanBtns
    function UI.RefreshChannel()
        for ch,btn in pairs(chanBtns) do ActiveToggle(btn,C.ui.accent[1],C.ui.accent[2],C.ui.accent[3],(RLT.db and RLT.db.channel==ch)) end
    end

    -- ── Quick Actions header ──────────────────────────────────
    SectionHdr("Quick Actions")
    local qaY = cur
    local qPrint=MakeButton(setp,"Print +1s to Chat",   158,26,C.ui.accent[1],C.ui.accent[2],C.ui.accent[3])
    local qReset=MakeButton(setp,"Reset ALL +1 Data",   158,26,C.ui.red[1],   C.ui.red[2],   C.ui.red[3])
    qPrint:SetPoint("TOPLEFT",setp,"TOPLEFT",8, qaY-6)
    qReset:SetPoint("TOPLEFT",setp,"TOPLEFT",174,qaY-6)
    local div2=BgTex(setp,0.25,0.25,0.25,1,"ARTWORK"); div2:SetHeight(1)
    div2:SetPoint("TOPLEFT",setp,"TOPLEFT",1,qaY-38); div2:SetPoint("TOPRIGHT",setp,"TOPRIGHT",-1,qaY-38)
    cur = cur - 38
    qPrint:SetScript("OnClick",function()
        local list={}; for fn,cnt in pairs(RLT.db.plusOnes) do if cnt and cnt>0 then list[#list+1]={name=fn,count=cnt} end end
        if #list==0 then Print("No +1 data."); return end
        table.sort(list,function(a,b) return a.count>b.count end)
        Print(Colorize(C.gold,"=== +1 Standings ==="))
        for _,e in ipairs(list) do Print(string.format("  %-20s  +%d",ShortName(e.name),e.count)) end
    end)
    qReset:SetScript("OnClick",function() RLT.db.plusOnes={}; UI.RefreshStandings(); Print("All +1 data wiped.") end)

    -- ── Commands header + list (fills remaining space) ────────
    SectionHdr("Commands")
    local cmdBg=BgTex(setp,C.ui.bgMid[1],C.ui.bgMid[2],C.ui.bgMid[3],1,"ARTWORK")
    cmdBg:SetPoint("TOPLEFT",setp,"TOPLEFT",1,cur); cmdBg:SetPoint("BOTTOMRIGHT",setp,"BOTTOMRIGHT",-1,0)
    local helpFS=setp:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    helpFS:SetPoint("TOPLEFT",setp,"TOPLEFT",PAD,cur-8); helpFS:SetWidth(WIN_W-24); helpFS:SetJustifyH("LEFT"); helpFS:SetSpacing(4)
    helpFS:SetText(
        "/rlt -- Toggle window\n"..
        "/rlt cancel -- Cancel session or stop timer\n"..
        "/rlt roll [item] [count] -- Start session manually\n"..
        "/rlt resolve -- Force resolve\n"..
        "/rlt addroll <n> <val> [ms|os|tmog] -- Add roll manually\n"..
        "/rlt setplusone <n> <count> -- Set a player +1\n"..
        "/rlt resetplusone <n> -- Reset one player\n"..
        "/rlt resetall -- Wipe all +1 data\n"..
        "/rlt log [n] -- Print last N decisions\n"..
        "/rlt test -- Load test data"
    )
    helpFS:SetTextColor(1,1,1,1)
    local verFS2 = setp:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    verFS2:SetPoint("BOTTOMRIGHT",setp,"BOTTOMRIGHT",-8,8)
    verFS2:SetText("|cff444444RaidLootTracker v"..VERSION.." by Koosche|r")
    function UI.Refresh()
        UI.RefreshRolls(); UI.RefreshStandings(); UI.RefreshLog()
        UI.RefreshAutoLoot(); UI.RefreshAutoTrade(); UI.RefreshChannel(); UI.RefreshMLMode(); UI.RefreshTimerDisp()
        if UI.RefreshMLQuick then UI.RefreshMLQuick() end
    end

    -- Minimap button — mirrors the exact layer technique used by WIM (confirmed working on 3.3.5a)
    local mmAngle = 220
    local mmBtn = CreateFrame("Button","RLTMinimapBtn",Minimap)
    mmBtn:SetWidth(31); mmBtn:SetHeight(31)
    mmBtn:SetFrameStrata("MEDIUM"); mmBtn:SetFrameLevel(8)
    mmBtn:SetMovable(true)
    mmBtn:RegisterForClicks("LeftButtonUp","RightButtonUp")
    mmBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- Overlay ring: MiniMap-TrackingBorder at 53x53 anchored TOPLEFT — masks the icon into a circle
    local mmOverlay = mmBtn:CreateTexture(nil,"OVERLAY")
    mmOverlay:SetWidth(53); mmOverlay:SetHeight(53)
    mmOverlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    mmOverlay:SetPoint("TOPLEFT")

    -- Background: TempPortraitAlphaMask gives the circular dark fill (exactly as WIM uses)
    local mmBg = mmBtn:CreateTexture(nil,"BACKGROUND")
    mmBg:SetWidth(20); mmBg:SetHeight(20)
    mmBg:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    mmBg:SetPoint("TOPLEFT",6,-6)
    mmBtn.bg = mmBg

    -- Icon: loot bag, trimmed slightly with SetTexCoord to avoid hard pixel edges
    local mmIcon = mmBtn:CreateTexture(nil,"BORDER")
    mmIcon:SetWidth(20); mmIcon:SetHeight(20)
    mmIcon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10")
    mmIcon:SetTexCoord(0.05,0.95,0.05,0.95)
    mmIcon:SetPoint("TOPLEFT",6,-5)
    mmBtn.icon = mmIcon

    mmBtn:SetScript("OnMouseDown",function(self)
        self.icon:SetTexCoord(0,1,0,1)
    end)
    mmBtn:SetScript("OnMouseUp",function(self)
        self.icon:SetTexCoord(0.05,0.95,0.05,0.95)
    end)

    local function PosMMBtn()
        local angle = math.rad(mmAngle)
        local x = math.cos(angle) * 80
        local y = math.sin(angle) * 80
        mmBtn:ClearAllPoints()
        mmBtn:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end
    PosMMBtn()
    mmBtn:RegisterForDrag("LeftButton")
    mmBtn:SetScript("OnDragStart",function(self)
        self:LockHighlight()
        self.icon:SetTexCoord(0,1,0,1)
        self:SetScript("OnUpdate",function()
            local mx,my = Minimap:GetCenter()
            local px,py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            px,py = px/scale, py/scale
            mmAngle = math.deg(math.atan2(py-my, px-mx)) % 360
            PosMMBtn()
        end)
    end)
    mmBtn:SetScript("OnDragStop",function(self)
        self:SetScript("OnUpdate",nil)
        self.icon:SetTexCoord(0.05,0.95,0.05,0.95)
        self:UnlockHighlight()
    end)
    mmBtn:SetScript("OnClick",function(self,btn)
        if btn=="LeftButton" then if f:IsShown() then f:Hide() else f:Show(); UI.Refresh() end end
    end)
    mmBtn:SetScript("OnEnter",function(self)
        GameTooltip:SetOwner(self,"ANCHOR_LEFT"); GameTooltip:SetText("RaidLootTracker",1,1,1)
        GameTooltip:AddLine("Click to toggle",0.7,0.7,0.7); GameTooltip:AddLine("Drag to reposition",0.7,0.7,0.7)
        if RLT.session then
            local n=0; for _ in pairs(RLT.session.rolls) do n=n+1 end
            GameTooltip:AddLine(RLT.session.itemName.." -- "..n.." rolls  "..math.ceil(RLT.timerRemaining).."s left",1,0.85,0,1)
        end
        GameTooltip:Show()
    end)
    mmBtn:SetScript("OnLeave",function() GameTooltip:Hide() end)
    SelectTab(1)
    return f
end

-- ============================================================
-- EVENTS
-- ============================================================
local masterFrame=CreateFrame("Frame","RLTMasterFrame",UIParent)
masterFrame:RegisterEvent("ADDON_LOADED")
masterFrame:RegisterEvent("CHAT_MSG_SYSTEM")
masterFrame:RegisterEvent("CHAT_MSG_SAY")
masterFrame:RegisterEvent("CHAT_MSG_YELL")
masterFrame:RegisterEvent("CHAT_MSG_PARTY")
masterFrame:RegisterEvent("CHAT_MSG_PARTY_LEADER")
masterFrame:RegisterEvent("CHAT_MSG_RAID")
masterFrame:RegisterEvent("CHAT_MSG_RAID_LEADER")
masterFrame:RegisterEvent("CHAT_MSG_WHISPER")
masterFrame:RegisterEvent("LOOT_OPENED")
masterFrame:RegisterEvent("TRADE_SHOW")
masterFrame:RegisterEvent("TRADE_CLOSED")
masterFrame:RegisterEvent("UI_INFO_MESSAGE")
masterFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

local autoLootWait=false; local autoLootElapsed=0

masterFrame:SetScript("OnUpdate",function(self,elapsed)
    -- Auto-loot delay
    if autoLootWait then
        autoLootElapsed=autoLootElapsed+elapsed
        if autoLootElapsed>=0.4 then
            autoLootWait=false; autoLootElapsed=0
            local dropped={}
            for i=1,GetNumLootItems() do
                local _,name,_,rarity=GetLootSlotInfo(i)
                if name and rarity and rarity>=2 then local lnk=GetLootSlotLink(i); if lnk then dropped[#dropped+1]=lnk end end
                LootSlot(i)
            end
            if #dropped>0 then Announce("[RLT] Boss dropped:"); for _,lnk in ipairs(dropped) do Announce("[RLT]   "..lnk) end end
        end
    end
    -- Countdown timer
    if RLT.timerActive and RLT.session then
        local prevSec = math.ceil(RLT.timerRemaining)
        RLT.timerRemaining = RLT.timerRemaining - elapsed
        local newSec = math.ceil(RLT.timerRemaining)

        if RLT.timerRemaining <= 0 then
            RLT.timerActive = false; RLT.timerRemaining = 0
            RLT.sessionClosed = true
            AnnounceWarn("Rolls CLOSED: " .. RLT.session.itemName)
            Announce("[RLT] Rolls closed for " .. RLT.session.itemLink .. " -- click Resolve to finalize.")
            if UI.main then UI.Refresh() end
        else
            -- Per-second big countdown during last 10 seconds
            if newSec <= 10 and newSec < prevSec and newSec > 0 then
                if newSec <= 5 then
                    -- Last 5s: giant red number flash
                    LocalRaidWarn(tostring(newSec))
                elseif newSec == 10 then
                    AnnounceWarn("[RLT] 10 seconds to roll for " .. RLT.session.itemName .. "!")
                else
                    -- 6-9: just local flash, no raid chat spam
                    LocalRaidWarn(tostring(newSec))
                end
            end
            if UI.main and UI.main:IsShown() and UI.activeTab == 1 then UI.RefreshRolls() end
        end
    end
end)

-- Auto-trade: fill trade slot when a winner opens trade with ML
local function OnTradeShow()
    if not TradeFrameRecipientNameText then return end
    local target=TradeFrameRecipientNameText:GetText()
    if not target or target=="" then return end
    local targetShort=(target:match("^([^%-]+)") or target):lower()
    if not RLT.db or not RLT.db.autoTrade then return end
    local itemLink=RLT.pendingTrades[targetShort]
    if not itemLink then return end
    local itemName=itemLink:match("%[(.-)%]")
    if not itemName then return end
    for bag=0,4 do
        for slot=1,GetContainerNumSlots(bag) do
            local sLink=GetContainerItemLink(bag,slot)
            if sLink and sLink:match("%[(.-)%]")==itemName then
                PickupContainerItem(bag,slot); ClickTradeButton(1)
                Print("Auto-traded "..itemLink.." to "..target)
                RLT.pendingTrades[targetShort]=nil; return
            end
        end
    end
    Print(Colorize(C.orange,"Item not found in bags: ")..itemLink)
end

-- tradePend: snapshot of items/target when trade button clicked
-- Announce only fires when WoW sends UI_INFO_MESSAGE "Trade complete."
-- which only happens on a real successful trade, never on cancel.
local tradePend={target="",items={}}
local function CaptureTrade()
    tradePend.target=(TradeFrameRecipientNameText and TradeFrameRecipientNameText:GetText()) or "Unknown"
    tradePend.items={}
    for i=1,(MAX_TRADE_ITEMS or 6)-1 do
        local name=GetTradePlayerItemInfo(i)
        if name then local lnk=GetTradePlayerItemLink(i); tradePend.items[#tradePend.items+1]=lnk or name end
    end
end

local function SenderIsMe(sender)
    if not sender then return false end
    local myName=UnitName("player"); if not myName then return false end
    local myFull=myName.."-"..(REALM_NAME or GetRealmName())
    return sender==myName or sender==myFull
end

masterFrame:SetScript("OnEvent",function(self,event,...)
    if event=="ADDON_LOADED" then
        local name=...
        if name~=ADDON_NAME then return end
        if type(RaidLootTrackerDB)~="table" then RaidLootTrackerDB={} end
        RLT.db=RaidLootTrackerDB
        for k,v in pairs(DB_DEFAULTS) do
            if RLT.db[k]==nil then RLT.db[k]=(type(v)=="table") and {} or v end
        end
        REALM_NAME=GetRealmName()
        BuildUI()
        if RLT.db.windowPos and RLT.db.windowPos.x then
            local s=UIParent:GetEffectiveScale()
            UI.main:ClearAllPoints()
            UI.main:SetPoint("BOTTOMLEFT",UIParent,"BOTTOMLEFT",RLT.db.windowPos.x/s,RLT.db.windowPos.y/s)
        else UI.main:SetPoint("CENTER",UIParent,"CENTER",0,0) end
        Print("v"..VERSION.." loaded  --  /rlt to open  --  ML Mode: "..(RLT.db.mlMode and "ON" or "OFF"))

    elseif event=="PLAYER_ENTERING_WORLD" then
        REALM_NAME=GetRealmName()

    elseif event=="CHAT_MSG_SYSTEM" then
        if not RLT.session then return end
        local msg=...
        local pName,rVal,_,rMax=msg:match("^(.+) rolls (%d+) %((%d+)%-(%d+)%)")
        if not pName then return end
        rVal=tonumber(rVal); rMax=tonumber(rMax)
        if rMax~=100 and rMax~=99 and rMax~=98 then return end
        local rollType=(rMax==100) and "MS" or (rMax==99 and "OS" or "Tmog")
        -- Normalize: strip any realm suffix from pName then re-apply via FullName
        -- so "Koosche" and "Koosche-Bronzebeard" both resolve to "Koosche-Bronzebeard"
        local shortOnly=pName:match("^([^%-]+)") or pName
        local fn=FullName(shortOnly)
        if RLT.session.rolls[fn] then Print(Colorize(C.grey,ShortName(fn).." already rolled.")); return end
        RLT.session.rolls[fn]={raw=rVal,rollType=rollType}
        local p=(rollType=="MS") and GetPlusOnes(fn) or 0
        local penStr=(p>0) and (" "..Colorize(C.orange,"[+"..p.."]")) or ""
        local typLbl=(rollType=="MS") and Colorize(C.green,"MS") or (rollType=="OS" and Colorize(C.blue,"OS") or Colorize(C.grey,"Tmog"))
        Print(ShortName(fn).." rolled "..Colorize(C.gold,tostring(rVal)).." ["..typLbl.."]"..penStr)
        if UI.main and UI.main:IsShown() and UI.activeTab==1 then UI.RefreshRolls() end

    elseif event=="CHAT_MSG_SAY" or event=="CHAT_MSG_YELL"
        or event=="CHAT_MSG_PARTY" or event=="CHAT_MSG_PARTY_LEADER"
        or event=="CHAT_MSG_RAID" or event=="CHAT_MSG_RAID_LEADER"
        or event=="CHAT_MSG_WHISPER" then
        local msg,sender=...
        -- ML Mode: we linked an item -> auto-start
        if RLT.db and RLT.db.mlMode and SenderIsMe(sender) and not RLT.session and not RLT.sessionClosed then
            local itemLink=msg:match("(|c%x+|Hitem:.-|h%[.-%]|h|r)")
            if itemLink then StartSession(itemLink,1); return end
        end
        -- Manual waiting mode
        if RLT.waitingForItem then
            local itemLink=msg:match("(|c%x+|Hitem:.-|h%[.-%]|h|r)")
            if itemLink then RLT.waitingForItem=false; StartSession(itemLink,1) end
        end

    elseif event=="LOOT_OPENED" then
        if not RLT.db or not RLT.db.autoLoot then return end
        local lootMethod,masterPartyID=GetLootMethod()
        if lootMethod~="master" then return end
        local isML=(masterPartyID==0)
        if not isML and IsInRaid() and masterPartyID then isML=UnitIsUnit("raid"..masterPartyID,"player")
        elseif not isML and masterPartyID then isML=UnitIsUnit("party"..masterPartyID,"player") end
        if not isML then return end
        autoLootWait=true; autoLootElapsed=0

    elseif event=="TRADE_SHOW" then
        OnTradeShow()
        if TradeFrameTradeButton and not TradeFrameTradeButton._rltHooked then
            TradeFrameTradeButton:HookScript("OnClick",CaptureTrade)
            TradeFrameTradeButton._rltHooked=true
        end

    elseif event=="TRADE_CLOSED" then
        -- Reset on close regardless; announce only happens via UI_INFO_MESSAGE below
        tradePend={target="",items={}}

    elseif event=="UI_INFO_MESSAGE" then
        -- Only fires "Trade complete." when BOTH sides confirmed -- never on cancel
        local msg=...
        if msg and msg:find("Trade complete") and RLT.db and RLT.db.autoTrade then
            if #tradePend.items>0 and tradePend.target~="" then
                for _,item in ipairs(tradePend.items) do
                    Announce(string.format("[RLT] %s traded %s to %s",UnitName("player"),item,tradePend.target))
                end
                if UI.main and UI.main:IsShown() then UI.RefreshLog() end
            end
        end
    end
end)

-- ============================================================
-- SLASH COMMANDS
-- ============================================================
SLASH_RLT1="/rlt"; SLASH_RLT2="/raidloot"
SlashCmdList["RLT"]=function(input)
    input=input or ""; local cmd,rest=input:match("^(%S+)%s*(.*)"); cmd=(cmd or ""):lower(); rest=rest or ""
    local function RA() if UI.main and UI.main:IsShown() then UI.Refresh() end end

    if cmd=="" then
        if UI.main then if UI.main:IsShown() then UI.main:Hide() else UI.main:Show(); UI.Refresh() end end

    elseif cmd=="help" then
        Print(Colorize(C.gold,"=== RaidLootTracker v"..VERSION.." ==="))
        local cmds={{"/rlt","Toggle window"},{"/rlt test","Load test data"},
            {"/rlt roll [item] [count]","Start session (or use ML Mode)"},
            {"/rlt resolve","Force-resolve"},  {"/rlt cancel","Cancel / stop timer"},
            {"/rlt addroll <n> <val> [ms|os]","Add roll manually"}, {"/rlt removeroll <n>","Remove roll"},
            {"/rlt showrolls","Print sorted order"}, {"/rlt plusones","Print +1 standings"},
            {"/rlt setplusone <n> <num>","Set +1 count"}, {"/rlt resetplusone <n>","Reset player"},
            {"/rlt resetall","Wipe all +1s"}, {"/rlt log [n]","Print last N decisions"},
            {"/rlt autoloot on|off","Toggle auto-loot"}, {"/rlt mlmode on|off","Toggle ML Mode"},
            {"/rlt channel raid|party|say","Announce channel"}, {"/rlt status","Show config"}}
        for _,r in ipairs(cmds) do Print(Colorize(C.gold,r[1]).." -- "..r[2]) end

    elseif cmd=="status" then
        Print("ML Mode: "..(RLT.db.mlMode and Colorize(C.green,"ON") or Colorize(C.red,"OFF")))
        Print("AutoLoot: "..(RLT.db.autoLoot and Colorize(C.green,"ON") or Colorize(C.red,"OFF")))
        Print("Channel: "..Colorize(C.gold,RLT.db.channel).."  Timer: "..RLT.db.rollTimer.."s")
        if RLT.session then
            local n=0; for _ in pairs(RLT.session.rolls) do n=n+1 end
            Print("Active: "..RLT.session.itemLink.." ("..n.." rolls, "..math.ceil(RLT.timerRemaining).."s left)")
        end

    elseif cmd=="mlmode" then
        if rest:lower()=="on" then RLT.db.mlMode=true; Print("ML Mode "..Colorize(C.green,"ON"))
        elseif rest:lower()=="off" then RLT.db.mlMode=false; Print("ML Mode "..Colorize(C.red,"OFF"))
        else PrintErr("Usage: /rlt mlmode on|off") end; RA()

    elseif cmd=="autoloot" then
        if rest:lower()=="on" then RLT.db.autoLoot=true; Print("Auto-loot "..Colorize(C.green,"ENABLED"))
        elseif rest:lower()=="off" then RLT.db.autoLoot=false; Print("Auto-loot "..Colorize(C.red,"DISABLED"))
        else PrintErr("Usage: /rlt autoloot on|off") end; RA()

    elseif cmd=="channel" then
        local arg=rest:upper()
        if arg=="RAID" or arg=="PARTY" or arg=="SAY" then RLT.db.channel=arg; Print("Channel: "..Colorize(C.gold,arg)); RA()
        else PrintErr("Usage: /rlt channel raid|party|say") end

    elseif cmd=="roll" then
        if RLT.session then PrintErr("Session active. /rlt resolve or /rlt cancel first."); return end
        local itemLink=rest:match("(|c%x+|Hitem:.-|h%[.-%]|h|r)")
        local afterLink
        if not itemLink then
            if rest=="" then
                RLT.waitingForItem=true
                Print(Colorize(C.gold,"Waiting for item link -- paste item in any chat channel."))
                if UI.main then UI.main:Show(); UI.SelectTab(1); UI.Refresh() end; return
            end
            local parts={}; for p in rest:gmatch("%S+") do parts[#parts+1]=p end
            itemLink=parts[1]; afterLink=rest:sub(#parts[1]+1)
        else afterLink=rest:gsub("|c%x+|H.-|h%[.-%]|h|r",""):gsub("|c%x+.-|r","") end
        local count=tonumber(afterLink:match("^%s*(%d+)%s*$")) or 1
        StartSession(itemLink,math.max(1,math.min(count,99)))

    elseif cmd=="resolve" then
        if not RLT.session then PrintErr("No active session."); return end
        local s=RLT.session; RLT.session=nil; RLT.sessionClosed=false; ResolveSession(s); RA()

    elseif cmd=="cancel" then
        if RLT.waitingForItem then RLT.waitingForItem=false; Print("Cancelled."); RA(); return end
        if not RLT.session then PrintErr("No active session."); return end
        RLT.timerActive=false; RLT.timerRemaining=0
        Print("Cancelled: "..RLT.session.itemLink); RLT.sessionClosed=false; RLT.session=nil; RA()

    elseif cmd=="addroll" then
        if not RLT.session then PrintErr("No active session."); return end
        local name,valStr,typeArg=rest:match("^(%S+)%s+(%d+)%s*(%a*)")
        if not name then PrintErr("Usage: /rlt addroll <n> <value> [ms|os]"); return end
        local rt=(typeArg and typeArg:lower()=="os") and "OS" or "MS"
        local fn=FullName(name); RLT.session.rolls[fn]={raw=tonumber(valStr),rollType=rt}
        Print("Added: "..ShortName(fn).." = "..Colorize(C.gold,valStr).." ["..rt.."]"); RA()

    elseif cmd=="removeroll" then
        if not RLT.session then PrintErr("No active session."); return end
        local name=rest:match("^(%S+)"); if not name then PrintErr("Usage: /rlt removeroll <n>"); return end
        local fn=FullName(name)
        if RLT.session.rolls[fn] then RLT.session.rolls[fn]=nil; Print("Removed "..ShortName(fn)); RA()
        else PrintErr("No roll for "..name) end

    elseif cmd=="showrolls" then
        if not RLT.session then PrintErr("No active session."); return end
        local sorted=SortedRollers(RLT.session)
        if #sorted==0 then Print("No rolls yet."); return end
        Print("Order -- "..RLT.session.itemLink.." ("..RLT.session.itemCount.." avail, "..math.ceil(RLT.timerRemaining).."s left):")
        for rank,e in ipairs(sorted) do
            local pen=(e.rollType=="MS" and e.plusOnes>0) and Colorize(C.orange," [+"..e.plusOnes.."]") or ""
            local win=(rank<=RLT.session.itemCount) and Colorize(C.green," WIN") or ""
            Print(string.format("  #%d %s -- %d [%s]%s%s",rank,e.short,e.raw,e.rollType,pen,win))
        end

    elseif cmd=="plusones" then
        local list={}; for fn,cnt in pairs(RLT.db.plusOnes) do if cnt and cnt>0 then list[#list+1]={name=fn,count=cnt} end end
        if #list==0 then Print("No +1 data."); return end
        table.sort(list,function(a,b) if a.count~=b.count then return a.count>b.count end; return a.name<b.name end)
        Print(Colorize(C.gold,"=== +1 Standings ===")); for _,e in ipairs(list) do Print(string.format("  %-20s  +%d",ShortName(e.name),e.count)) end

    elseif cmd=="setplusone" then
        local name,valStr=rest:match("^(%S+)%s+(%d+)")
        if not name then PrintErr("Usage: /rlt setplusone <n> <number>"); return end
        SetPlusOnes(FullName(name),tonumber(valStr)); Print(name.."'s +1 set to "..Colorize(C.gold,valStr)); RA()

    elseif cmd=="resetplusone" then
        local name=rest:match("^(%S+)"); if not name then PrintErr("Usage: /rlt resetplusone <n>"); return end
        SetPlusOnes(FullName(name),0); Print(name.." reset to 0."); RA()

    elseif cmd=="resetall" then
        RLT.db.plusOnes={}; Print(Colorize(C.red,"All +1 data wiped.")); RA()

    elseif cmd=="log" then
        local n=tonumber(rest) or 10; local log=RLT.db.lootLog
        if #log==0 then Print("Log empty."); return end
        n=math.min(n,#log); Print(Colorize(C.gold,"=== Last "..n.." Decisions ==="))
        for i=#log,math.max(1,#log-n+1),-1 do
            local e=log[i]; local wns={}
            for _,w in ipairs(e.winners or {}) do wns[#wns+1]=ShortName(w.name)..(w.rollType=="OS" and "(OS)" or "") end
            Print(string.format("  [%s] %s -> %s",e.date or "?",e.itemName or "?",#wns>0 and table.concat(wns,", ") or "none"))
        end

    elseif cmd=="test" then
        if RLT.session then PrintErr("Cancel current session first."); return end
        local realm=REALM_NAME or GetRealmName()
        RLT.session=NewSession("[Thunderfurries lawl]",2)
        local td={{name="Twas",roll=87,rollType="MS",plusOnes=2},{name="Loot",roll=94,rollType="MS",plusOnes=1},
                  {name="But a",roll=42,rollType="MS",plusOnes=0},{name="Test",roll=71,rollType="OS",plusOnes=0},
                  {name="Scratch",roll=55,rollType="MS",plusOnes=0},{name="Addon",roll=99,rollType="MS",plusOnes=1}}
        for _,p in ipairs(td) do
            local fn=p.name.."-"..realm; RLT.session.rolls[fn]={raw=p.roll,rollType=p.rollType}
            if p.plusOnes>0 then RLT.db.plusOnes[fn]=p.plusOnes end
        end
        RLT.timerRemaining=RLT.db.rollTimer; RLT.timerActive=true
        Print(Colorize(C.orange,"[TEST]").." 6 fake players, 30s timer.")
        if UI.main then UI.main:Show(); UI.SelectTab(1); UI.Refresh() end
    else
        PrintErr("Unknown: '"..cmd.."'. /rlt help")
    end
end