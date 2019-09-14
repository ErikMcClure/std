local cond = require 'std.cond'
local CT = require 'std.constraint'

local M = {}

--LLVM knows how to optimize this. simple implementation, and rely on the optimizer.
terra M.default_copy_raw(dest: &opaque, src: &opaque, len: intptr)
  var dest_int8 = [&int8](dest)
  var src_int8 = [&int8](src)
  for offset = 0,len do
    dest_int8[offset] = src_int8[offset]
  end
end

--LLVM knows how to optimize this. simple implementation, and rely on the optimizer.
M.default_clear_raw = terralib.overloadedfunction( "defaultClearRaw", {
    terra (ptr: &opaque, len: intptr)
      var ptr_ = [&uint8](ptr)
      for offset = 0,len do
        ptr_[offset] = 0
      end
    end,
    terra (ptr: &opaque, len: intptr, val: uint8)
      var ptr_ = [&uint8](ptr)
      for offset = 0,len do
        ptr_[offset] = val
      end
    end
  }
)

function M.wrap_func_as_macro_method(func)
  return macro(function(self, ...)
    local args = {...}
    return `func([...])
  end)
end

-- This defines a raw allocation interface used to generate a type safe allocator interface
M.RawAllocator = CT.All(
  CT.Method("alloc", {intptr}, &opaque),
  CT.Method("free", {&opaque}, nil),
  CT.Any + CT.Method("clear", {&opaque, intptr, intptr}, nil),
  CT.Any + CT.Method("calloc", {intptr}, &opaque),
  CT.Any + CT.Method("realloc", {&opaque, intptr, intptr}, &opaque), -- First int is old size, second int is new size. Some realloc implementations may throw away the old size parameter.
  CT.Any + CT.Method("copy", {&opaque, &opaque, intptr}, nil)
)

-- This defines a type-safe allocator interface that can be overriden directly or generated from a raw allocator
M.Allocator = CT.All(
  CT.MetaConstraint(function(a) return CT.Method("alloc", {CT.Type(a), CT.Integral}, CT.Pointer(a)) end, CT.TerraType),
  CT.Method("free", {CT.Pointer(CT.TerraType)}, nil),
  CT.Method("clear", {CT.Pointer(CT.TerraType), CT.Integral, CT.Integral}, nil),
  CT.MetaConstraint(function(a) return CT.Method("calloc", {CT.Type(a), CT.Integral}, CT.Pointer(a)) end, CT.TerraType),
  CT.MetaConstraint(function(a) return CT.Method("realloc", {CT.Pointer(a), CT.Integral, CT.Integral}, CT.Pointer(a)) end, CT.TerraType),
  CT.MetaConstraint(function(a) return CT.Method("copy", {CT.Pointer(a),CT.Pointer(a),CT.Integral}, nil) end, CT.TerraType)
)

-- libC allocator is the default allocator. It uses libc functions to perform memory manipulations.
local malloc = terralib.externfunction("malloc", {intptr} -> {&opaque})
local free = terralib.externfunction("free", {&opaque} -> {})
local calloc = terralib.externfunction("calloc", {intptr, intptr}-> {&opaque})
local realloc = terralib.externfunction("realloc", {&opaque, intptr}-> {&opaque})
local memcpy = terralib.externfunction("memcpy", {&opaque, &opaque, intptr} -> {})
local memset = terralib.externfunction("memset", {&opaque, int32, intptr} -> {})

struct M.libc_allocator {}

terra M.libc_allocator:alloc(size: intptr): &opaque
  return malloc(size)
end

terra M.libc_allocator:free(ptr: &opaque): {}
  free(ptr)
end

terra M.libc_allocator:clear(dest: &opaque, value: intptr, size: intptr): {}
  memset(dest, value, size)
end

terra M.libc_allocator:calloc(size: intptr, nelems: intptr): &opaque
  return calloc(size, nelems)
end

terra M.libc_allocator:realloc(ptr: &opaque, old_size: intptr, new_size: intptr): &opaque
  return realloc(ptr, new_size)
end

terra M.libc_allocator:copy(dest: &opaque, src: &opaque, size: intptr): {}
  memcpy(dest, src, size)
end

-- Populate the methods of an allocator
-- Some methods can have working defaults.
-- Some high level APIs can be derived from low level APIs
-- By composing all of these derivations, allocators can be made easily from a minimal set of functionality.
M.GenerateAllocator = CT.Meta({CT.Type(M.RawAllocator)}, CT.Type(M.Allocator),
function(allocator)
  if not allocator:getmethod 'alloc' then
    error "allocator doesn't have alloc defined and no default behavior is available"
  end
  allocator.methods.alloc_raw = allocator.methods.alloc
  allocator.methods.alloc = CT.Expression(function(a) return CT.MetaMethod(allocator, {CT.Type(a), CT.Integral}, CT.Pointer(a),
  function(self, T, len)
    if not len then len = 1 end
    local type = T:astype()
    return `[&type](self:alloc_raw([terralib.sizeof(type)]*len))
  end) end, CT.TerraType)

  if not allocator:getmethod 'free' then
    error "allocator doesn't have free defined and no default behavior is available"
  end
  allocator.methods.free_raw = allocator.methods.free
  allocator.methods.free = CT.MetaMethod(allocator, {CT.Pointer(CT.TerraType)}, nil,
  function(self, ptr)
    return quote
      self:free_raw([&opaque](ptr))
    end
  end)

  allocator.methods.clear_raw = allocator.methods.clear
  if not allocator:getmethod 'clear_raw' then
    allocator.methods.clear_raw = macro(function(self, ptr, len, val)
      if not val then
        return `M.defaultClearRaw(ptr, len)
      else
        return `M.defaultClearRaw(ptr, len, val)
      end
    end)
  end
  allocator.methods.clear = CT.MetaMethod(allocator, {CT.Pointer(CT.TerraType), CT.Integral, CT.Integral}, nil,
  function(self, ptr, len, val)
    local type = ptr:gettype().type --base type of pointer
    if val then
      return `self:clear_raw([&opaque](ptr), len*[terralib.sizeof(type)], val)
    else
      return `self:clear_raw([&opaque](ptr), len*[terralib.sizeof(type)])
    end
  end)

  allocator.methods.calloc_raw = allocator.methods.calloc
  if not allocator:getmethod 'calloc_raw' then
    terra allocator:calloc_raw(size: intptr, nelems: intptr)
      var regionsize = size * nelems
      var region = self:alloc_raw(regionsize)
      self:clear_raw(region, regionsize)
      return region
    end
  end
  allocator.methods.calloc = CT.Expression(function(a) return CT.MetaMethod(allocator, {CT.Type(a), CT.Integral}, CT.Pointer(a),
  function (self, T, nelems)
    local type = T:astype()
    return `[&type](self:calloc_raw([terralib.sizeof(type)], nelems))
  end) end, CT.TerraType)

  allocator.methods.copy_raw = allocator.methods.copy
  if not allocator:getmethod 'copy_raw' then
    allocator.methods.copy_raw = macro(function(self, dest, src, len)
      return `M.default_copy_raw(dest, src, len)
    end)
  end

  allocator.methods.copy = CT.Expression(function(a) return CT.MetaMethod(allocator, {CT.Pointer(a),CT.Pointer(a),CT.Integral}, nil,
  function(self, dest, src, len)
    if dest:gettype() ~= src:gettype() then
      error "source and destination pointers of a copy are of different types. allocator copying cannot handle type casting or conversion."
    end
    return `self:copy_raw([&opaque](dest), [&opaque](src), len*[terralib.sizeof(dest:gettype().type)])
  end) end, CT.TerraType)

  allocator.methods.realloc_raw = allocator.methods.realloc
  if not allocator:getmethod 'realloc_raw' then
    allocator.methods.realloc_raw = macro(function(self, ptr, old_size, new_size)
      return quote
        var self_ = self
        var new_size_ = new_size
        var old_size_ = old_size
        var new_ptr = self_:alloc(new_size_)
        self_:copy_raw(new_ptr, ptr, cond(new_size_ < old_size_, new_size_, old_size_))
      in
        new_ptr
      end
    end)
  end
  
  allocator.methods.realloc = CT.Expression(function(a) return CT.MetaMethod(allocator, {CT.Pointer(a), CT.Integral, CT.Integral}, CT.Pointer(a),
  function(self, ptr, old_size, new_size)
    local type = ptr:gettype().type
    return `[&type](self:realloc_raw([&opaque](ptr), old_size * [terralib.sizeof(type)], new_size * [terralib.sizeof(type)]))
  end) end, CT.TerraType)

  return allocator
end)

M.GenerateAllocator(M.libc_allocator)

M.default_allocator = global(M.libc_allocator)

M.alloc = macro(function(T, len) return `M.default_allocator:alloc(T, len) end)
M.free = macro(function(ptr) return `M.default_allocator:free(ptr) end)
M.clear = macro(function(ptr, len, val) return `M.default_allocator:clear(ptr, len, val) end)
M.calloc = macro(function(T, len) return `M.default_allocator:calloc(T, len) end)
M.realloc = macro(function(ptr, old, len) return `M.default_allocator:realloc(ptr, old, len) end)
M.copy = macro(function(dest, src, len) return `M.default_allocator:copy(dest, src, len) end)

return M