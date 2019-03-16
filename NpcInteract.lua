_addon.name = 'NpcInteract'
_addon.author = 'DiscipleOfEris'
_addon.version = '1.1.1'
_addon.command = 'npc'

require('logger')
require('tables')
require('strings')
local packets = require('packets')
require('coroutine')
local res = require('resources')
res.chat[6] = {id=6,en='system'}

config = require('config')
texts = require('texts')

defaults = {}
defaults.show = true
defaults.mirror = false
defaults.fade = 10
defaults.display = {}
defaults.display.pos = {}
defaults.display.pos.x = 0
defaults.display.pos.y = 0
defaults.display.bg = {}
defaults.display.bg.red = 0
defaults.display.bg.green = 0
defaults.display.bg.blue = 0
defaults.display.bg.alpha = 127
defaults.display.text = {}
defaults.display.text.font = 'Consolas'
defaults.display.text.red = 255
defaults.display.text.green = 255
defaults.display.text.blue = 255
defaults.display.text.alpha = 255
defaults.display.text.size = 10

settings = config.load(defaults)
box = texts.new("", settings.display, settings)

local report_info = T{}

local PACKET = { ZONE_OUT = 0x00B, INCOMING_CHAT = 0x017, ACTION = 0x01A, DIALOG_CHOICE = 0x05B, NPC_INTERACT_1 = 0x032, NPC_INTERACT_2 = 0x034, UPDATE_CHAR = 0x037, NPC_RELEASE = 0x052 }
local ACTION_CATEGORY = { NPC_INTERACTION = 0 }

-- NPC interactions sometimes fail. Only clone interactions with NPC_INTERACT_1, NPC_INTERACT_2, or ZONE_OUT response.
-- For NPC_INTERACT_1 and NPC_INTERACT_2, we must track UPDATE_CHAR's Status == 4 (Event). Interaction ends with Status = 0 (Idle).
-- For ZONE_OUT, we just need to catch it within a few seconds of NPC_RELEASE.


local injecting = false
local attempts = 0
local npc
local npc_id = 0
local last_packet = nil
local last_idle_packet = nil
local last_broadcast = nil
local status = 0
local prev_status = 0
local busy = false
local success = false
local response_id
local out = T{}
local inc = false

local last_update_time = os.clock()
local fade_duration = 2

local MAX_ATTEMPTS = 20

packets.raw_fields.incoming[PACKET.NPC_RELEASE] = L{
  {ctype='int',      label='_unknown1'},
}

windower.register_event('login', function()
  last_update_time = os.clock()
  coroutine.sleep(5)
  if settings.mirror then log('Mirroring enabled. Other chars will attempt to clone interactions.') end
end)

windower.register_event('addon command', function(command, ...)
  args = T{...}
  command = command:lower()
  
  if not command or command == 'help'  then
    log('npc mirror [on/off] -- Toggle/enable/disable mirroring, causing all other alts to mirror this one.')
    log('npc report [on/off] -- Toggle/enable/disable reporting, showing when alts successfully mirror the main.')
    log('npc retry -- Retry the last NPC interaction.')
    log('npc reset -- Try this if alts get frozen when attempting to interact with an NPC.')
  elseif command == 'mirror' then
    if not args[1] then
      settings.mirror = not settings.mirror
    elseif args[1] == 'on' then
      settings.mirror = true
    elseif args[1] == 'off' then
      settings.mirror = false
    end
    
    if settings.mirror then log('Mirroring enabled. Other chars will attempt to clone interactions.')
    else log('Mirroring disabled.') end
    config.save(settings)
  elseif command == 'reset' then
    reset()
  elseif command == 'retry' then
    log('retry', last_broadcast)
    if settings.mirror and last_broadcast then
      windower.send_ipc_message(last_broadcast)
    elseif last_broadcast then
      local outs = msgStr:split(' out ')
      local pre = outs:remove(1):split(' ')
      npc_id = tonumber(pre[2])
      inc = tonumber(pre[3])
      out = outs
      inject()
    end
  elseif command == 'report' then
    if not args[1] then
      settings.show = not settings.show
    elseif args[1] == 'on' then
      settings.show = true
    elseif args[2] == 'off' then
      settings.show = false
    end
    
    config.save(settings)
  elseif command == 'fade' then
    local fade_time = tonumber(args[1])
    if fade_time and fade_time > 0 then
      settings.fade = fade_time
    else
      settings.fade = 0
    end
    
    config.save(settings)
  end
end)

windower.register_event('ipc message', function(msgStr)
  --log('start', msgStr)
  
  local args = T(msgStr:split(' '))
  local command = args:remove(1)
  
  if command == 'action' then
    --log('action')
  elseif command == 'dialog' then
    --log('dialog')
  elseif command == 'broadcast' then
    last_broadcast = msgStr
    local outs = msgStr:split(' out ')
    local pre = outs:remove(1):split(' ')
    npc_id = tonumber(pre[2])
    inc = tonumber(pre[3])
    out = outs
    inject()
  elseif command == 'success' then
    local name = args[1]
    local id = args[2]
    
    report_info[name] = true
    if settings.mirror then last_update_time = os.clock() end
  end
end)

windower.register_event('prerender', function()
  updateInfo()
  doFade()
end)

windower.register_event('outgoing chunk', function(id, original, modified, injected, blocked)
  if id == PACKET.ACTION then
    packet = packets.parse('outgoing', original)
    
    if packet.Category == ACTION_CATEGORY.NPC_INTERACTION and settings.mirror --[[and not injected--]] then
      busy = true
      success = false
      out = T{}
      inc = false
      npc_id = packet.Target
      npc = windower.ffxi.get_mob_by_id(packet.Target)
      if settings.mirror then last_update_time = os.clock() end
    end
  elseif id == PACKET.DIALOG_CHOICE then
    packet = packets.parse('outgoing', original)
    last_packet = packet
    --log('dialog', injected)
    
    if settings.mirror --[[and not injected--]] then
      local target_id = packet['Target']
      if target_id == windower.ffxi.get_player()['id'] then target_id = 'me' end
      
      out:insert(T{target_id, packet['Option Index'], packet['_unknown1'], packet['Target Index'], tostring(packet['Automated Message']), packet['_unknown2'], packet['Zone'], packet['Menu ID']})
      last_update_time = os.clock()
    end
  end
end)

windower.register_event('incoming chunk', function(id, original, modified, injected, blocked)
  if not busy and not injecting and not success then return end
  
  if id == PACKET.NPC_INTERACT_1 or id == PACKET.NPC_INTERACT_2 then
    local packet = packets.parse('incoming', original)
    --log('npc interact', (id == PACKET.NPC_INTERACT_1 and 1 or 2))
    success = 1
    inc = id
    if injecting then
      for _, o in ipairs(out) do
        o = o:split(' ')
        local target_id = o[1]
        local index = tonumber(o[4])
        local zone = tonumber(o[7])
        local automated = false
        if o[5] == 'true' then automated = true end
        
        local self = windower.ffxi.get_mob_by_target('me')
        local info = windower.ffxi.get_info()
        
        if target_id == 'me' then target_id = self.id
        else target_id = tonumber(target_id) end
        
        local packet = packets.new('outgoing', PACKET.DIALOG_CHOICE, {
          ['Target'] = target_id,
          ['Option Index'] = tonumber(o[2]),
          ['_unknown1'] = o[3],
          ['Target Index'] = tonumber(o[4]),
          ['Automated Message'] = automated,
          ['_unknown2'] = tonumber(o[6]),
          ['Zone'] = zone,
          ['Menu ID'] = tonumber(o[8])
        })
        
        --log('dialog')
        last_packet = packet
        packets.inject(packet)
      end
      return true
    end
  elseif id == PACKET.ZONE_OUT then
    busy = false
    success = true
    inc = id
  elseif id == PACKET.UPDATE_CHAR then
    local packet = packets.parse('incoming', original)
    status = packet.Status
    
    --log('status', status)
    
    if status == 0 and prev_status == 4 then
      if success and settings.mirror and not busy then
        broadcast()
        success = false
      end
      
      busy = false
      injecting = false
    end
    prev_status = status
  elseif id == PACKET.NPC_RELEASE then
    released = os.time()
    --log('release', success, busy)
    coroutine.sleep(1)
    --log('sleep', success, busy)
    if success == 1 and settings.mirror then
      success = true
      if status == 0 then busy = false end
    elseif success and settings.mirror and status == 0 and not busy then
      broadcast()
      success = false
      busy = false
    elseif success and not settings.mirror then
      injecting = false
      local self = windower.ffxi.get_player()
      windower.send_ipc_message('success '..self.name)
    elseif not success and injecting and attempts < MAX_ATTEMPTS then
      attempts = attempts + 1
      retry()
    end
  end
end)

function broadcast()
  if not npc_id then return end
  
  local outs = T{}
  for _, v in ipairs(out) do
    --log(v)
    outs:insert(v:concat(' '))
  end
  
  local msg = 'broadcast '..npc_id..' '..inc..' out '..outs:concat(' out ')
  
  --print(msg)
  --log(msg)
  report_info = T{}
  windower.send_ipc_message(msg)
  last_broadcast = msg
  last_npc = npc
  last_update_time = os.clock()
end

function inject()
  local npc = windower.ffxi.get_mob_by_id(npc_id)
  local self = windower.ffxi.get_mob_by_target('me')
  
  success = false
  busy = false
  attempts = 0
  
  if not self or not npc or distance(self, npc) > 6.0 then return end
  
  injecting = true
  
  local packet = packets.new('outgoing', PACKET.ACTION, {
    ['Target'] = npc_id,
    ['Target Index'] = npc.index,
    ['Category'] = ACTION_CATEGORY.NPC_INTERACTION,
    ['Param'] = 0
  })
  
  --log('action')
  packets.inject(packet)
end

function retry()
  local npc = windower.ffxi.get_mob_by_id(npc_id)
  local self = windower.ffxi.get_mob_by_target('me')
  
  if not self or not npc or distance(self, npc) > 6.0 then return end
  
  injecting = true
  
  local packet = packets.new('outgoing', PACKET.ACTION, {
    ['Target'] = npc_id,
    ['Target Index'] = npc.index,
    ['Category'] = ACTION_CATEGORY.NPC_INTERACTION,
    ['Param'] = 0
  })
  
  --log('retry', attempts)
  packets.inject(packet)
end

function reset()
  -- Resetting against last poked npc.
  local self = windower.ffxi.get_mob_by_target('me')
  local zone = windower.ffxi.get_info().zone
  if last_packet then 
    local packet = packets.new('outgoing', PACKET.DIALOG_CHOICE, {
      ['Target'] = last_packet['Target'],
      ['Option Index'] = '0',
      ['_unknown1'] = '16384',
      ['Target Index'] = last_packet['Target Index'],
      ['Automated Message'] = false,
      ['_unknown2'] = 0,
      ['Zone'] = last_packet['Zone'],
      ['Menu ID'] = last_packet['Menu ID']
    })
    
    packets.inject(packet)
    windower.add_to_chat(10,'Should be reset now. Please try again.')
  else
    windower.add_to_chat(10,'You are not listed as in a menu interaction. Ignoring.')
  end
end

function updateInfo()
  box:visible(settings.show)
  local lines = T{}
  for name, status in pairs(report_info) do
    lines:insert(name..' √')
  end
  local maxWidth = math.max(1, table.reduce(lines, function(a, b) return math.max(a, #b) end, '1'))
  for i,line in ipairs(lines) do lines[i] = lines[i]:lpad(' ', maxWidth) end
  
  if not npc then lines:insert(1, 'Mirroring '..(settings.mirror and 'enabled' or 'disabled'))
  else
    if last_npc and last_npc.id == npc_id then
      if #lines == 0 then lines:insert('Broadcasting...') end
      lines:insert(1, 'NPC: '..last_npc.name)
    else
      lines = T{'Interacting...'}
    end
  end
  
  box:text(lines:concat('\n'))
end

function doFade()
  local opacity = 1
  local diff = os.clock() - last_update_time
  
  if diff < settings.fade then
    opacity = 1
  elseif diff < settings.fade + fade_duration then
    opacity = 1 - (diff-settings.fade) / fade_duration
  else
    opacity = 0
  end
  
  box:alpha(opacity*defaults.display.text.alpha)
  box:bg_alpha(opacity*defaults.display.bg.alpha)
  
  if opacity == 0 then box:visible(false) end
end

function distance(A, B)
  return math.sqrt((A.x - B.x)^2 + (A.y - B.y)^2)
end
