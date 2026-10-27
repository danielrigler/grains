local Installer = {}
Installer.__index = Installer

local RESTART_CMD = "sudo systemctl restart norns-jack.service norns-crone.service norns-matron.service"

local MSG = {
  nogit = {"Not Installed via Git", "Reinstall from maiden"},
  offline = {"Can't Reach Server", "Check WiFi and try again"},
  current = {"Grains is Up to Date", "Nothing new to install"},
  edited = {"Update Skipped", "Local files were modified"},
  failed = {"Update Failed", "Check WiFi and try again"}
}

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function git(self, args)
  return trim(util.os_capture("git -C '" .. self.path .. "' " .. args .. " 2>/dev/null"))
end

function Installer.new()
  local m = setmetatable({}, Installer)
  m.path = trim(norns.state.path):gsub("/$", "")
  m.update = {state = nil, behind = 0, message = nil}
  m.cfg = norns.state.data .. "auto_update"
  local f = io.open(m.cfg, "r")
  m.auto = f ~= nil and f:read("*l") == "1"
  if f then f:close() end
  return m
end

function Installer:set_auto(on)
  if on == self.auto then return end
  self.auto = on
  local f = io.open(self.cfg, "w")
  if f then f:write(on and "1" or "0") f:close() end
end

function Installer:check(manual)
  local u, s = self.update, self.update.state
  if s == "checking" then if manual then u.state = "searching" end return end
  if s and s ~= "info" and s ~= "update" then return end
  u.state = manual and "searching" or "checking"
  local g = "nice -n 19 git -C '" .. self.path .. "' "
  norns.system_cmd("if " .. g .. "rev-parse --is-inside-work-tree >/dev/null 2>&1; then timeout -k 5 20 " .. g .. "fetch --quiet 2>/dev/null; echo F$?; echo B$(" .. g .. "rev-list --count HEAD..@{u} 2>/dev/null); echo D$(" .. g .. "status --porcelain --untracked-files=no 2>/dev/null | wc -l); fi; echo _done_", function(out)
    out = out or ""
    local f = out:match("F(%d+)")
    u.behind = tonumber(out:match("B(%d+)")) or 0
    local msg = not f and MSG.nogit or f ~= "0" and MSG.offline
      or u.behind <= 0 and MSG.current
      or (tonumber(out:match("D(%d+)")) or 0) > 0 and MSG.edited
    if not msg then u.state = "update" return end
    print("[installer] " .. msg[1] .. ": " .. msg[2])
    u.state, u.message = u.state == "searching" and "info" or nil, msg
  end)
end

function Installer:install_update()
  self.update.state = "installing"
  self.update.message = nil
  norns.system_cmd("git -C '" .. self.path .. "' pull --ff-only 2>&1", function()
    if (tonumber(git(self, "rev-list --count HEAD..@{u}")) or 0) == 0 then
      if git(self, "diff --name-only ORIG_HEAD..HEAD -- '*.sc' '*.scd'") ~= "" then
        self.update.state = "restart"
      else
        self.update.state = "reloading"
        clock.run(function() clock.sleep(0.4) norns.rerun() end)
      end
    else
      self.update.message = MSG.failed
      self.update.state = "info"
    end
  end)
end

function Installer:do_restart()
  self.update.state = "restarting"
  os.execute(RESTART_CMD)
end

local PENDING_STATES = {
  update = true, installing = true, reloading = true, searching = true,
  restart = true, restarting = true, info = true
}

function Installer:pending()
  return PENDING_STATES[self.update.state] == true
end

function Installer:key(k, z)
  if z ~= 1 then return end
  local s = self.update.state
  if s == "update" then
    if k == 2 then self.update.state = nil
    elseif k == 3 then clock.run(function() self:install_update() end) end
  elseif s == "restart" then
    if k == 2 then self.update.state = nil
    elseif k == 3 then self:do_restart() end
  elseif s == "info" then
    if k == 2 or k == 3 then self.update.state = nil end
  end
end

local function line(y, txt, lvl)
  screen.level(lvl or 15)
  screen.move(64, y)
  screen.text_center(txt)
end

function Installer:redraw()
  screen.clear()
  screen.blend_mode(0)
  local s = self.update.state
  if s == "update" then
    local n = self.update.behind
    line(18, "Grains Update Available")
    line(30, n .. " new commit" .. (n == 1 and "" or "s"), 1)
    line(46, "K2: Skip   K3: Install")
  elseif s == "searching" then
    line(28, "Checking for Updates...")
  elseif s == "installing" then
    line(28, "Installing Update...")
  elseif s == "reloading" then
    line(28, "Updated - Reloading...")
  elseif s == "restart" then
    line(16, "Update Installed.")
    line(28, "New Engine - Restart Needed", 1)
    line(44, "K2: Later   K3: Restart")
  elseif s == "restarting" then
    line(28, "Restarting...")
  elseif s == "info" then
    local m = self.update.message or MSG.failed
    line(18, m[1])
    line(30, m[2], 1)
    line(46, "K2/K3: Dismiss")
  end
  screen.update()
end

return Installer
