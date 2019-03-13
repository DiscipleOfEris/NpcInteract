_addon.name = 'NpcInteract'
_addon.author = 'DiscipleOfEris'
_addon.version = '1.0.0'
_addon.command = 'npc'

require('logger')
require('tables')
require('strings')
local packets = require('packets')
require('coroutine')
local res = require('resources')
res.chat[6] = {id=6,en='system'}

local PACKET = { ZONE_OUT = 0x00B, INCOMING_CHAT = 0x017, ACTION = 0x01A, DIALOG_CHOICE = 0x05B, NPC_INTERACT_1 = 0x032, NPC_INTERACT_2 = 0x034, UPDATE_CHAR = 0x037, NPC_RELEASE = 0x052 }
local ACTION_CATEGORY = { NPC_INTERACTION = 0 }

-- NPC interactions sometimes fail. Only clone interactions with NPC_INTERACT_1, NPC_INTERACT_2, or ZONE_OUT response.
-- For NPC_INTERACT_1 and NPC_INTERACT_2, we must track UPDATE_CHAR's Status == 4 (Event). Interaction ends with Status = 0 (Idle).
-- For ZONE_OUT, we just need to catch it within a few seconds of NPC_RELEASE.


local mirroring = false
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

local MAX_ATTEMPTS = 20

packets.raw_fields.incoming[PACKET.NPC_RELEASE] = L{
  {ctype='int',      label='_unknown1'},
}

windower.register_event('addon command', function(command, ...)
  args = T{...}
  command = command:lower()
  
  if not command then
  
  elseif command == 'mirror' then
    if not args[1] then
      mirroring = not mirroring
    elseif args[1] == 'on' then
      mirroring = true
    elseif args[1] == 'off' then
      mirroring = false
    end
    
    if mirroring then log('Mirroring enabled. Other chars will attempt to clone interactions.')
    else log('Mirroring disabled.') end
  elseif command == 'reset' then
    reset()
  elseif command == 'retry' then
    log('retry', last_broadcast)
    if mirroring and last_broadcast then
      windower.send_ipc_message(last_broadcast)
    elseif last_broadcast then
      local outs = msgStr:split(' out ')
      local pre = outs:remove(1):split(' ')
      npc_id = tonumber(pre[2])
      inc = tonumber(pre[3])
      out = outs
      inject()
    end
  elseif command == 'test' then
    packets.inject(last_idle_packet)
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
  end
end)

windower.register_event('outgoing chunk', function(id, original, modified, injected, blocked)
  if id == PACKET.ACTION then
    packet = packets.parse('outgoing', original)
    
    if packet.Category == ACTION_CATEGORY.NPC_INTERACTION then
      last_npc = windower.ffxi.get_mob_by_index(packet['Target Index'])
      --log('action', injected)
    end
    
    if packet.Category == ACTION_CATEGORY.NPC_INTERACTION and mirroring --[[and not injected--]] then
      busy = true
      success = false
      out = T{}
      inc = false
      npc_id = packet.Target
      npc = windower.ffxi.get_mob_by_id(packet.Target)
    end
  elseif id == PACKET.DIALOG_CHOICE then
    packet = packets.parse('outgoing', original)
    last_packet = packet
    --log('dialog', injected)
    
    if mirroring --[[and not injected--]] then
      local target_id = packet['Target']
      if target_id == windower.ffxi.get_player()['id'] then target_id = 'me' end
      
      out:insert(T{target_id, packet['Option Index'], packet['_unknown1'], packet['Target Index'], tostring(packet['Automated Message']), packet['_unknown2'], packet['Zone'], packet['Menu ID']})
    end
  end
end)

windower.register_event('incoming chunk', function(id, original, modified, injected, blocked)
  if not busy and not injecting and not success then return end
  
  if id == PACKET.NPC_INTERACT_1 or id == PACKET.NPC_INTERACT_2 then
    local packet = packets.parse('incoming', original)
    log('npc interact', (id == PACKET.NPC_INTERACT_1 and 1 or 2))
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
      if success and mirroring and not busy then
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
    if success == 1 and mirroring then
      success = true
      if status == 0 then busy = false end
    elseif success and mirroring and status == 0 and not busy then
      broadcast()
      success = false
      busy = false
    elseif success and not mirroring then
      injecting = false
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
  windower.send_ipc_message(msg)
  last_broadcast = msg
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

function distance(A, B)
  return math.sqrt((A.x - B.x)^2 + (A.y - B.y)^2)
end
