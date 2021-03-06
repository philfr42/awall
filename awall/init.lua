--[[
Alpine Wall main module
Copyright (C) 2012-2016 Kaarle Ritvanen
See LICENSE file for license details
]]--


local M = {}

local class = require('awall.class')
local resolve = require('awall.dependency')
local IPSet = require('awall.ipset')
local IPTables = require('awall.iptables').IPTables

local optfrag = require('awall.optfrag')
local combinations = optfrag.combinations

M.PolicySet = require('awall.policy')

local util = require('awall.util')
local extend = util.extend


local posix = require('posix')
local chdir = posix.chdir

local stringy = require('stringy')


local events
local procorder
local achains

function M.loadmodules(path)
   events = {}
   achains = {}

   local function readmetadata(mod)
      local export = mod.export or {}
      for name, target in pairs(export) do events[name] = target end

      extend(achains, mod.achains)

      return util.keys(export)
   end

   readmetadata(require('awall.model'))

   local cdir = posix.getcwd()
   if path then assert(chdir(path)) end

   local modules = {}
   for _, modfile in ipairs(
      posix.dir((path or '/usr/share')..'/awall/modules')
   ) do
      if stringy.endswith(modfile, '.lua') then
	 table.insert(modules, 'awall.modules.'..modfile:sub(1, -5))
      end
   end
   table.sort(modules)

   local imported = {}
   for i, name in ipairs(modules) do
      extend(imported, readmetadata(require(name)))
   end

   assert(chdir(cdir))

   events['%modules'] = {before=imported}
   procorder = resolve(events)
end

function M.loadclass(path)
   assert(path:sub(1, 1) ~= '%')
   return events[path] and events[path].class
end


M.Config = class()

function M.Config:init(policyconfig)

   self.objects = policyconfig:expand()
   self.iptables = IPTables()

   local actions = {}

   local function insertrules(trules, obj)
      for i, trule in ipairs(trules) do
	 local t = self.iptables.config[trule.family][trule.table][trule.chain]
	 local opts = optfrag.command(trule)

	 if trule.target then
	    local acfrag = {
	       family=trule.family,
	       table=trule.table,
	       chain=trule.target
	    }
	    local key = optfrag.location(acfrag)
	    if not actions[key] then
	       actions[key] = true
	       if stringy.startswith(trule.target, 'custom:') then
		  local name = trule.target:sub(8, -1)
		  local rules = (self.objects.custom or {})[name]
		  if not rules then
		     obj:error('Invalid custom chain: '..name)
		  end
		  insertrules(
		     combinations(
			{{chain=trule.target}}, util.list(rules), {acfrag}
		     ),
		     rules
		  )
	       else insertrules(combinations(achains, {acfrag})) end
	    end
	 end

	 if trule.position == 'prepend' then
	    table.insert(t, 1, opts)
	 else
	    table.insert(t, opts)
	 end
      end
   end

   for i, path in ipairs(procorder) do
      if path:sub(1, 1) ~= '%' then
	 local objs = self.objects[path]
	 if objs then
	    for k, v in pairs(objs) do
	       objs[k] = events[path].class.morph(
		  v,
		  self,
		  path..' '..k..' ('..policyconfig.source[path][k]..')'
	       )
	    end
	 end
      end
   end

   for i, event in ipairs(procorder) do
      if event:sub(1, 1) == '%' then
	 local r = events[event].rules
	 if r then
	    if type(r) == 'function' then r = r(self.objects) end
	    if r then
	       assert(type(r) == 'table')
	       insertrules(r)
	    end
	 end
      elseif self.objects[event] then
	 for i, rule in ipairs(self.objects[event]) do
	    insertrules(rule:trules(), rule)
	 end
      end
   end

   self.ipset = IPSet(self.objects.ipset)
end

function M.Config:print()
   self.ipset:print()
   io.write('\n')
   self.iptables:print()
end

function M.Config:dump(dir)
   self.ipset:dump(dir and dir..'/ipset-' or '/etc/ipset.d/')
   self.iptables:dump(dir or '/etc/iptables')
end

function M.Config:test()
   self.ipset:create()
   self.iptables:test()
end

function M.Config:activate()
   self:test()
   self.iptables:activate()
end


return M
