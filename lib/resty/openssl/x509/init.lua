local ffi = require "ffi"
local C = ffi.C
local ffi_gc = ffi.gc
local ffi_new = ffi.new
local ffi_str = ffi.string
local ffi_cast = ffi.cast

require "resty.openssl.include.x509"
require "resty.openssl.include.x509v3"
require "resty.openssl.include.evp"
require "resty.openssl.include.objects"
local stack_macro = require("resty.openssl.include.stack")
local stack_lib = require("resty.openssl.stack")
local asn1_lib = require("resty.openssl.asn1")
local digest_lib = require("resty.openssl.digest")
local extension_lib = require("resty.openssl.x509.extension")
local util = require("resty.openssl.util")
local format_error = require("resty.openssl.err").format_error
local OPENSSL_10 = require("resty.openssl.version").OPENSSL_10
local OPENSSL_11 = require("resty.openssl.version").OPENSSL_11


-- accessors provides an openssl version neutral interface to lua layer
-- it doesn't handle any error, expect that to be implemented in
-- _M.set_X or _M.get_X
local accessors = {}

accessors.set_pubkey = C.X509_set_pubkey
accessors.set_version = C.X509_set_version
accessors.set_serial_number = C.X509_set_serialNumber
accessors.set_subject_name = C.X509_set_subject_name
accessors.set_issuer_name = C.X509_set_issuer_name

if OPENSSL_11 then
  -- generally, use get1 if we return a lua table wrapped ctx which doesn't support dup.
  -- in that case, a new struct is returned from C api, and we will handle gc.
  -- openssl will increment the reference count for returned ptr, and won't free it when
  -- parent struct is freed.
  -- otherwise, use get0, which returns an internal pointer, we don't need to free it up.
  -- it will be gone together with the parent struct.
  accessors.set_not_before = C.X509_set1_notBefore
  accessors.get_not_before = C.X509_get0_notBefore -- returns internal ptr, we convert to number
  accessors.set_not_after = C.X509_set1_notAfter
  accessors.get_not_after = C.X509_get0_notAfter -- returns internal ptr, we convert to number
  accessors.get_pubkey = C.X509_get_pubkey -- returns new evp_pkey instance, don't need to dup
  accessors.get_version = C.X509_get_version -- returns int
  accessors.get_serial_number = C.X509_get0_serialNumber -- returns internal ptr, we convert to bn
  accessors.get_subject_name = C.X509_get_subject_name -- returns internal ptr, we dup it
  accessors.get_issuer_name = C.X509_get_issuer_name -- returns internal ptr, we dup it
elseif OPENSSL_10 then
  accessors.set_not_before = C.X509_set_notBefore
  accessors.get_not_before = function(x509)
    if x509 == nil or x509.cert_info == nil or x509.cert_info.validity == nil then
      return nil
    end
    return x509.cert_info.validity.notBefore
  end
  accessors.set_not_after = C.X509_set_notAfter
  accessors.get_not_after = function(x509)
    if x509 == nil or x509.cert_info == nil or x509.cert_info.validity == nil then
      return nil
    end
    return x509.cert_info.validity.notAfter
  end
  accessors.get_pubkey = C.X509_get_pubkey -- returns new evp_pkey instance, don't need to dup
  accessors.get_version = function(x509)
    return C.ASN1_INTEGER_get(x509.cert_info.version)
  end
  accessors.get_serial_number = C.X509_get_serialNumber -- returns internal ptr, we convert to bn
  accessors.get_subject_name = C.X509_get_subject_name -- returns internal ptr, we dup it
  accessors.get_issuer_name = C.X509_get_issuer_name -- returns internal ptr, we dup it
end

local _M = {}
local mt = { __index = _M }

local x509_ptr_ct = ffi.typeof("X509*")

-- only PEM format is supported for now
function _M.new(cert)
  local ctx
  if not cert then
    -- routine for create a new cert
    ctx = C.X509_new()
    if ctx == nil then
      return nil, format_error("x509.new")
    end
    ffi_gc(ctx, C.X509_free)

    C.X509_gmtime_adj(accessors.get_not_before(ctx), 0)
    C.X509_gmtime_adj(accessors.get_not_after(ctx), 0)
  elseif type(cert) == "string" then
    -- routine for load an existing cert
    local bio = C.BIO_new_mem_buf(cert, #cert)
    if bio == nil then
      return nil, format_error("x509.new: BIO_new_mem_buf")
    end

    ctx = C.PEM_read_bio_X509(bio, nil, nil, nil)
    C.BIO_free(bio)
    if ctx == nil then
      return nil, format_error("x509.new")
    end
    ffi_gc(ctx, C.X509_free)
  else
    return nil, "expect nil or a string at #1"
  end

  local self = setmetatable({
    ctx = ctx,
  }, mt)

  return self, nil
end

function _M.istype(l)
  return l and l.ctx and ffi.istype(x509_ptr_ct, l.ctx)
end

function _M.dup(ctx)
  if not ffi.istype(x509_ptr_ct, ctx) then
    return nil, "expect a x509 ctx at #1"
  end
  local ctx = C.X509_dup(ctx)
  if ctx == nil then
    return nil, "X509_dup() failed"
  end

  ffi_gc(ctx, C.X509_free)

  local self = setmetatable({
    ctx = ctx,
  }, mt)

  return self, nil
end

function _M:set_lifetime(not_before, not_after)
  local ok, err
  if not_before then
    ok, err = self:set_not_before(not_before)
    if err then
      return ok, err
    end
  end

  if not_after then
    ok, err = self:set_not_after(not_after)
    if err then
      return ok, err
    end
  end

  return true
end

function _M:get_lifetime()
  local not_before, err = self:get_not_before()
  if not_before == nil then
    return nil, nil, err
  end
  local not_after, err = self:get_not_after()
  if not_after == nil then
    return nil, nil, err
  end

  return not_before, not_after, nil
end

-- note: index is 0 based
local OPENSSL_STRING_value_at = function(ctx, i)
  local ct = ffi_cast("OPENSSL_STRING", stack_macro.OPENSSL_sk_value(ctx, i))
  if ct == nil then
    return nil
  end
  return ffi_str(ct)
end

function _M:get_ocsp_url(return_all)
  local st = C.X509_get1_ocsp(self.ctx)
  local ret
  if return_all then
    ret = {}
    local count = stack_macro.OPENSSL_sk_num(st)
    for i=0,count do
      ret[i+1] = OPENSSL_STRING_value_at(st, i)
    end
  else
    ret = OPENSSL_STRING_value_at(st, 0)
  end

  C.X509_email_free(st)
  return ret
end

function _M:get_ocsp_request()

end

function _M:get_crl_url(return_all)
  local cdp, err = self:get_crl_distribution_points()
  if err then
    return nil, err
  end

  if cdp:count() == 0 then
    return
  end

  if return_all then
    local ret = {}
    local cdp_iter = cdp:each()
    while true do
      local _, gn = cdp_iter()
      if not gn then
        break
      end
      local gn_iter = gn:each()
      while true do
        local k, v = gn_iter()
        if not k then
          break
        elseif k == "URI" then
          table.insert(ret, v)
        end
      end
    end
    return ret
  else
    local gn, err = cdp:index(1)
    if err then
      return nil, err
    end
    local iter = gn:each()
    while true do
      local k, v = iter()
      if not k then
        break
      elseif k == "URI" then
        return v
      end
    end
  end
end

function _M:sign(pkey, digest)
  local pkey_lib = require("resty.openssl.pkey")
  if not pkey_lib.istype(pkey) then
    return false, "expect a pkey instance at #1"
  end
  if digest and  not digest_lib.istype(digest) then
    return false, "expect a digest instance at #2"
  end

  -- returns size of signature if success
  if C.X509_sign(self.ctx, pkey.ctx, digest and digest.ctx) == 0 then
    return false, format_error("x509:sign")
  end

  return true
end

local uint_ptr = ffi.typeof("unsigned int[1]")

local function digest(self, cfunc, typ)
  -- TODO: dedup the following with resty.openssl.digest
  local ctx
  if OPENSSL_11 then
    ctx = C.EVP_MD_CTX_new()
    ffi_gc(ctx, C.EVP_MD_CTX_free)
  elseif OPENSSL_10 then
    ctx = C.EVP_MD_CTX_create()
    ffi_gc(ctx, C.EVP_MD_CTX_destroy)
  end
  if ctx == nil then
    return nil, "failed to create EVP_MD_CTX"
  end

  local dtyp = C.EVP_get_digestbyname(typ or 'sha1')
  if dtyp == nil then
    return nil, string.format("invalid digest type \"%s\"", typ)
  end

  local md_size = C.EVP_MD_size(dtyp)
  local buf = ffi_new('unsigned char[?]', md_size)
  local length = uint_ptr()

  if cfunc(self.ctx, dtyp, buf, length) ~= 1 then
    return nil, format_error("x509:digest")
  end

  return ffi_str(buf, length[0])
end

function _M:digest(typ)
  return digest(self, C.X509_digest, typ)
end

function _M:pubkey_digest(typ)
  return digest(self, C.X509_pubkey_digest, typ)
end

function _M:to_PEM()
  return util.read_using_bio(C.PEM_write_bio_X509, self.ctx)
end

local function get_x509_ext_by_nid(ctx, nid, pos)
  local loc = C.X509_get_ext_by_NID(ctx, nid, pos or -1)
  if loc == -1 then
    return nil, nil, format_error("get_x509_ext_by_nid: X509_get_ext_by_NID")
  end

  local ext = C.X509_get_ext(ctx, loc)
  if ext == nil then
    return nil, nil, format_error("get_x509_ext_by_nid: X509_get_ext")
  end
  return ext, loc
end

local function get_x509_ext_by_txt_nid(ctx, txt_nid, pos)
  local nid
  if type(txt_nid) == "string" then
    nid = C.OBJ_txt2nid(txt_nid)
    if nid == 0 then
      return nil, nil, "invalid NID text " .. nid
    end
  elseif type(txt_nid) == "number" then
    nid = txt_nid
  else
    return nil, nil, "expect string or number at #1"
  end

  return get_x509_ext_by_nid(ctx, nid, pos)
end

function _M:add_extension(extension)
  if not extension_lib.istype(extension) then
    return false, "expect a x509.extension instance at #1"
  end

  -- X509_add_ext returnes the stack on success, and NULL on error
  -- the X509_EXTENSION ctx is dupped internally
  if C.X509_add_ext(self.ctx, extension.ctx, -1) == nil then
    return false, format_error("x509:add_extension")
  end

  return true
end

function _M:get_extension(nid_txt, last_pos)
  last_pos = (last_pos or 0) - 1

  local ctx, pos, err = get_x509_ext_by_txt_nid(self.ctx, nid_txt, last_pos)
  if err then
    return nil, nil, err
  end
  if pos == -1 then
    return nil
  end
  local ext, err = extension_lib.dup(ctx)
  if err then
    return nil, nil, err
  end
  return ext, pos+1
end

local X509_delete_ext
if OPENSSL_11 then
  X509_delete_ext = C.X509_delete_ext
elseif OPENSSL_10 then
  X509_delete_ext = function(ctx, pos)
    return C.X509v3_delete_ext(ctx.cert_info.extensions, pos)
  end
else
  X509_delete_ext = function(...)
    error("X509_delete_ext undefined")
  end
end

function _M:set_extension(extension, last_pos)
  if not extension_lib.istype(extension) then
    return false, "expect a x509.extension instance at #1"
  end

  last_pos = (last_pos or 0) - 1

  local nid = extension:get_object().nid
  local _, pos, err = get_x509_ext_by_nid(self.ctx, nid, last_pos)
  if err then
    return false, err
  end

  local removed = X509_delete_ext(self.ctx, pos)
  C.X509_EXTENSION_free(removed)

  if C.X509_add_ext(self.ctx, extension.ctx, pos) == nil then
    return false, format_error("x509:add_extension")
  end

  return true
end


function _M:set_critical(nid_txt, crit)
  local ext, _, err = get_x509_ext_by_txt_nid(self.ctx, nid_txt)
  if err then
    return false, err
  end

  if C.X509_EXTENSION_set_critical(ext, crit and 1 or 0) ~= 1 then
    return false, format_error("X509_EXTENSION_set_critical")
  end

  return true
end

function _M:get_critical(nid_txt)
  local ext, _, err = get_x509_ext_by_txt_nid(self.ctx, nid_txt)
  if err then
    return nil, err
  end

  return C.X509_EXTENSION_get_critical(ext) == 1
end

-- START AUTO GENERATED CODE

-- AUTO GENERATED
function _M:set_serial_number(toset)

  local lib = require("resty.openssl.bn")
  if lib.istype and not lib.istype(toset) then
    return false, "expect a resty.openssl.bn instance at #1"
  end
  toset = toset.ctx
  toset = C.BN_to_ASN1_INTEGER(toset, nil)
  if toset == nil then
    return false, format_error("x509:set: BN_to_ASN1_INTEGER")
  end
  -- "A copy of the serial number is used internally
  -- so serial should be freed up after use.""
  ffi_gc(toset, C.ASN1_INTEGER_free)

  if accessors.set_serial_number(self.ctx, toset) == 0 then
    return false, format_error("x509:set_serial_number")
  end

  return true
end

-- AUTO GENERATED
function _M:get_serial_number()
  local got = accessors.get_serial_number(self.ctx)
  if got == nil then
    return nil, format_error("x509:get_serial_number")
  end

  -- returns a new BIGNUM instance
  got = C.ASN1_INTEGER_to_BN(got, nil)
  if got == nil then
    return false, format_error("x509:set: BN_to_ASN1_INTEGER")
  end
  -- bn will be duplicated thus this ctx should be freed up
  ffi_gc(got, C.BN_free)

  local lib = require("resty.openssl.bn")
  -- the internal ptr is returned, ie we need to copy it
  return lib.dup(got)
end

-- AUTO GENERATED
function _M:set_not_before(toset)

  if type(toset) ~= "number" then
    return false, "expect a number at #1"
  end
  toset = C.ASN1_TIME_set(nil, toset)
  ffi_gc(toset, C.ASN1_STRING_free)

  if accessors.set_not_before(self.ctx, toset) == 0 then
    return false, format_error("x509:set_not_before")
  end

  return true
end

-- AUTO GENERATED
function _M:get_not_before()
  local got = accessors.get_not_before(self.ctx)
  if got == nil then
    return nil, format_error("x509:get_not_before")
  end

  got = asn1_lib.asn1_to_unix(got)

  return got
end

-- AUTO GENERATED
function _M:set_not_after(toset)

  if type(toset) ~= "number" then
    return false, "expect a number at #1"
  end
  toset = C.ASN1_TIME_set(nil, toset)
  ffi_gc(toset, C.ASN1_STRING_free)

  if accessors.set_not_after(self.ctx, toset) == 0 then
    return false, format_error("x509:set_not_after")
  end

  return true
end

-- AUTO GENERATED
function _M:get_not_after()
  local got = accessors.get_not_after(self.ctx)
  if got == nil then
    return nil, format_error("x509:get_not_after")
  end

  got = asn1_lib.asn1_to_unix(got)

  return got
end

-- AUTO GENERATED
function _M:set_pubkey(toset)

  local lib = require("resty.openssl.pkey")
  if lib.istype and not lib.istype(toset) then
    return false, "expect a resty.openssl.pkey instance at #1"
  end
  toset = toset.ctx
  if accessors.set_pubkey(self.ctx, toset) == 0 then
    return false, format_error("x509:set_pubkey")
  end

  return true
end

-- AUTO GENERATED
function _M:get_pubkey()
  local got = accessors.get_pubkey(self.ctx)
  if got == nil then
    return nil, format_error("x509:get_pubkey")
  end

  local lib = require("resty.openssl.pkey")
  -- returned a copied instance directly
  return lib.new(got)
end

-- AUTO GENERATED
function _M:set_subject_name(toset)

  local lib = require("resty.openssl.x509.name")
  if lib.istype and not lib.istype(toset) then
    return false, "expect a resty.openssl.x509.name instance at #1"
  end
  toset = toset.ctx
  if accessors.set_subject_name(self.ctx, toset) == 0 then
    return false, format_error("x509:set_subject_name")
  end

  return true
end

-- AUTO GENERATED
function _M:get_subject_name()
  local got = accessors.get_subject_name(self.ctx)
  if got == nil then
    return nil, format_error("x509:get_subject_name")
  end

  local lib = require("resty.openssl.x509.name")
  -- the internal ptr is returned, ie we need to copy it
  return lib.dup(got)
end

-- AUTO GENERATED
function _M:set_issuer_name(toset)

  local lib = require("resty.openssl.x509.name")
  if lib.istype and not lib.istype(toset) then
    return false, "expect a resty.openssl.x509.name instance at #1"
  end
  toset = toset.ctx
  if accessors.set_issuer_name(self.ctx, toset) == 0 then
    return false, format_error("x509:set_issuer_name")
  end

  return true
end

-- AUTO GENERATED
function _M:get_issuer_name()
  local got = accessors.get_issuer_name(self.ctx)
  if got == nil then
    return nil, format_error("x509:get_issuer_name")
  end

  local lib = require("resty.openssl.x509.name")
  -- the internal ptr is returned, ie we need to copy it
  return lib.dup(got)
end

-- AUTO GENERATED
function _M:set_version(toset)

  if type(toset) ~= "number" then
    return false, "expect a number at #1"
  end
  -- Note: this is defined by standards (X.509 et al) to be one less than the certificate version.
  -- So a version 3 certificate will return 2 and a version 1 certificate will return 0.
  toset = toset - 1

  if accessors.set_version(self.ctx, toset) == 0 then
    return false, format_error("x509:set_version")
  end

  return true
end

-- AUTO GENERATED
function _M:get_version()
  local got = accessors.get_version(self.ctx)
  if got == nil then
    return nil, format_error("x509:get_version")
  end

  got = tonumber(got) + 1

  return got
end

local NID_subject_alt_name = C.OBJ_sn2nid("subjectAltName")
assert(NID_subject_alt_name ~= 0)

-- AUTO GENERATED: EXTENSIONS
function _M:set_subject_alt_name(toset)

  local lib = require("resty.openssl.x509.altname")
  if lib.istype and not lib.istype(toset) then
    return false, "expect a resty.openssl.x509.altname instance at #1"
  end
  toset = toset.ctx
  -- x509v3.h: # define X509V3_ADD_REPLACE              2L
  if C.X509_add1_ext_i2d(self.ctx, NID_subject_alt_name, toset, 0, 0x2) ~= 1 then
    return false, format_error("x509:set_subject_alt_name")
  end

  return true
end

-- AUTO GENERATED: EXTENSIONS
function _M:set_subject_alt_name_critical(crit)
  return _M.set_critical(self, NID_subject_alt_name, crit)
end

-- AUTO GENERATED: EXTENSIONS
function _M:get_subject_alt_name()
  -- X509_get_ext_d2i returns internal pointer, always dup
  local got = C.X509_get_ext_d2i(self.ctx, NID_subject_alt_name, nil, nil)
  if got == nil then
    return nil, format_error("x509:get_subject_alt_name")
  end

  -- Note: here we only free the stack itself not elements
  -- since there seems no way to increase ref count for a GENERAL_NAME
  -- we left the elements referenced by the new-dup'ed stack
  ffi_gc(got, stack_lib.gc_of("GENERAL_NAME"))
  got = ffi_cast("GENERAL_NAMES*", got)
  local lib = require("resty.openssl.x509.altname")
  -- the internal ptr is returned, ie we need to copy it
  return lib.dup(got)
end

-- AUTO GENERATED: EXTENSIONS
function _M:get_subject_alt_name_critical()
  return _M.get_critical(self, NID_subject_alt_name)
end

local NID_issuer_alt_name = C.OBJ_sn2nid("issuerAltName")
assert(NID_issuer_alt_name ~= 0)

-- AUTO GENERATED: EXTENSIONS
function _M:set_issuer_alt_name(toset)

  local lib = require("resty.openssl.x509.altname")
  if lib.istype and not lib.istype(toset) then
    return false, "expect a resty.openssl.x509.altname instance at #1"
  end
  toset = toset.ctx
  -- x509v3.h: # define X509V3_ADD_REPLACE              2L
  if C.X509_add1_ext_i2d(self.ctx, NID_issuer_alt_name, toset, 0, 0x2) ~= 1 then
    return false, format_error("x509:set_issuer_alt_name")
  end

  return true
end

-- AUTO GENERATED: EXTENSIONS
function _M:set_issuer_alt_name_critical(crit)
  return _M.set_critical(self, NID_issuer_alt_name, crit)
end

-- AUTO GENERATED: EXTENSIONS
function _M:get_issuer_alt_name()
  -- X509_get_ext_d2i returns internal pointer, always dup
  local got = C.X509_get_ext_d2i(self.ctx, NID_issuer_alt_name, nil, nil)
  if got == nil then
    return nil, format_error("x509:get_issuer_alt_name")
  end

  -- Note: here we only free the stack itself not elements
  -- since there seems no way to increase ref count for a GENERAL_NAME
  -- we left the elements referenced by the new-dup'ed stack
  ffi_gc(got, stack_lib.gc_of("GENERAL_NAME"))
  got = ffi_cast("GENERAL_NAMES*", got)
  local lib = require("resty.openssl.x509.altname")
  -- the internal ptr is returned, ie we need to copy it
  return lib.dup(got)
end

-- AUTO GENERATED: EXTENSIONS
function _M:get_issuer_alt_name_critical()
  return _M.get_critical(self, NID_issuer_alt_name)
end

local NID_basic_constraints = C.OBJ_sn2nid("basicConstraints")
assert(NID_basic_constraints ~= 0)

-- AUTO GENERATED: EXTENSIONS
function _M:set_basic_constraints(toset)

  if type(toset) ~= "table" then
    return false, "expect a table at #1"
  end
  local cfg_lower = {}
  for k, v in pairs(toset) do
    cfg_lower[string.lower(k)] = v
  end

  toset = C.BASIC_CONSTRAINTS_new()
  if toset == nil then
    return false, format_error("x509:set_BASIC_CONSTRAINTS")
  end
  ffi_gc(toset, C.BASIC_CONSTRAINTS_free)

  toset.ca = cfg_lower.ca and 0xFF or 0
  local pathlen = cfg_lower.pathlen and tonumber(cfg_lower.pathlen)
  if pathlen then
    C.ASN1_INTEGER_free(toset.pathlen)

    local asn1 = C.ASN1_STRING_type_new(pathlen)
    if asn1 == nil then
      return false, format_error("x509:set_BASIC_CONSTRAINTS: ASN1_STRING_type_new")
    end
    toset.pathlen = asn1

    local code = C.ASN1_INTEGER_set(asn1, pathlen)
    if code ~= 1 then
      return false, format_error("x509:set_BASIC_CONSTRAINTS: ASN1_INTEGER_set", code)
    end
  end


  -- x509v3.h: # define X509V3_ADD_REPLACE              2L
  if C.X509_add1_ext_i2d(self.ctx, NID_basic_constraints, toset, 0, 0x2) ~= 1 then
    return false, format_error("x509:set_basic_constraints")
  end

  return true
end

-- AUTO GENERATED: EXTENSIONS
function _M:set_basic_constraints_critical(crit)
  return _M.set_critical(self, NID_basic_constraints, crit)
end

-- AUTO GENERATED: EXTENSIONS
function _M:get_basic_constraints(name)
  -- X509_get_ext_d2i returns internal pointer, always dup
  local got = C.X509_get_ext_d2i(self.ctx, NID_basic_constraints, nil, nil)
  if got == nil then
    return nil, format_error("x509:get_basic_constraints")
  end

  local ctx = ffi_cast("BASIC_CONSTRAINTS*", got)

  local ca = ctx.ca == 0xFF
  local pathlen = tonumber(C.ASN1_INTEGER_get(ctx.pathlen))

  C.BASIC_CONSTRAINTS_free(ctx)

  if not name or type(name) ~= "string" then
    got = {
      ca = ca,
      pathlen = pathlen,
    }
  elseif string.lower(name) == "ca" then
    got = ca
  elseif string.lower(name) == "pathlen" then
    got = pathlen
  end

  return got
end

-- AUTO GENERATED: EXTENSIONS
function _M:get_basic_constraints_critical()
  return _M.get_critical(self, NID_basic_constraints)
end

local NID_info_access = C.OBJ_sn2nid("authorityInfoAccess")
assert(NID_info_access ~= 0)

-- AUTO GENERATED: EXTENSIONS
function _M:set_info_access(toset)

  local lib = require("resty.openssl.x509.extension.info_access")
  if lib.istype and not lib.istype(toset) then
    return false, "expect a resty.openssl.x509.extension.info_access instance at #1"
  end
  toset = toset.ctx
  -- x509v3.h: # define X509V3_ADD_REPLACE              2L
  if C.X509_add1_ext_i2d(self.ctx, NID_info_access, toset, 0, 0x2) ~= 1 then
    return false, format_error("x509:set_info_access")
  end

  return true
end

-- AUTO GENERATED: EXTENSIONS
function _M:set_info_access_critical(crit)
  return _M.set_critical(self, NID_info_access, crit)
end

-- AUTO GENERATED: EXTENSIONS
function _M:get_info_access()
  -- X509_get_ext_d2i returns internal pointer, always dup
  local got = C.X509_get_ext_d2i(self.ctx, NID_info_access, nil, nil)
  if got == nil then
    return nil, format_error("x509:get_info_access")
  end

  -- Note: here we only free the stack itself not elements
  -- since there seems no way to increase ref count for a ACCESS_DESCRIPTION
  -- we left the elements referenced by the new-dup'ed stack
  ffi_gc(got, stack_lib.gc_of("ACCESS_DESCRIPTION"))
  got = ffi_cast("AUTHORITY_INFO_ACCESS*", got)
  local lib = require("resty.openssl.x509.extension.info_access")
  -- the internal ptr is returned, ie we need to copy it
  return lib.dup(got)
end

-- AUTO GENERATED: EXTENSIONS
function _M:get_info_access_critical()
  return _M.get_critical(self, NID_info_access)
end

local NID_crl_distribution_points = C.OBJ_sn2nid("crlDistributionPoints")
assert(NID_crl_distribution_points ~= 0)

-- AUTO GENERATED: EXTENSIONS
function _M:set_crl_distribution_points(toset)

  local lib = require("resty.openssl.x509.extension.dist_points")
  if lib.istype and not lib.istype(toset) then
    return false, "expect a resty.openssl.x509.extension.dist_points instance at #1"
  end
  toset = toset.ctx
  -- x509v3.h: # define X509V3_ADD_REPLACE              2L
  if C.X509_add1_ext_i2d(self.ctx, NID_crl_distribution_points, toset, 0, 0x2) ~= 1 then
    return false, format_error("x509:set_crl_distribution_points")
  end

  return true
end

-- AUTO GENERATED: EXTENSIONS
function _M:set_crl_distribution_points_critical(crit)
  return _M.set_critical(self, NID_crl_distribution_points, crit)
end

-- AUTO GENERATED: EXTENSIONS
function _M:get_crl_distribution_points()
  -- X509_get_ext_d2i returns internal pointer, always dup
  local got = C.X509_get_ext_d2i(self.ctx, NID_crl_distribution_points, nil, nil)
  if got == nil then
    return nil, format_error("x509:get_crl_distribution_points")
  end

  -- Note: here we only free the stack itself not elements
  -- since there seems no way to increase ref count for a DIST_POINT
  -- we left the elements referenced by the new-dup'ed stack
  ffi_gc(got, stack_lib.gc_of("DIST_POINT"))
  got = ffi_cast("OPENSSL_STACK*", got)
  local lib = require("resty.openssl.x509.extension.dist_points")
  -- the internal ptr is returned, ie we need to copy it
  return lib.dup(got)
end

-- AUTO GENERATED: EXTENSIONS
function _M:get_crl_distribution_points_critical()
  return _M.get_critical(self, NID_crl_distribution_points)
end

-- END AUTO GENERATED CODE

return _M
