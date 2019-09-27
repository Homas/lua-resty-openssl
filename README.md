# lua-resty-openssl

FFI-based OpenSSL binding for LuaJIT, supporting OpenSSL 1.1 and 1.0.2 series

![Build Status](https://travis-ci.com/fffonion/lua-resty-openssl.svg?branch=master)


Table of Contents
=================

- [Description](#description)
- [Status](#status)
- [Synopsis](#synopsis)
- [TODO](#todo)
- [Copyright and License](#copyright-and-license)
- [See Also](#see-also)


Description
===========

`lua-resty-openssl` is a FFI-based OpenSSL binding library, currently
supports OpenSSL `1.1.1`, `1.1.0` and `1.0.2` series.

The API is kept as same [luaossl](https://github.com/wahern/luaossl) while only a small sets
of OpenSSL API implemented.


[Back to TOC](#table-of-contents)

Status
========

Production.

Synopsis
========

## resty.openssl

This meta module provides a version sanity check and returns all exported modules to a local table

```lua
return {
  _VERSION = '0.1.0',
  version = require("resty.openssl.version"),
  pkey = require("resty.openssl.pkey"),
  x509 = require("resty.openssl.x509"),
  name = require("resty.openssl.x509.name"),
  altname = require("resty.openssl.x509.altname"),
  csr = require("resty.openssl.x509.csr"),
  digest = require("resty.openssl.digest")
}
```

## resty.openssl.version

A module to provide version info.

### version_num

The OpenSSL version number.

### OPENSSL_11

A boolean indicates whether the linked OpenSSL is 1.1 series.

### OPENSSL_10

A boolean indicates whether the linked OpenSSL is 1.0 series.

## resty.openssl.pkey

Module to provide EVP infrastructure.

### pkey.new

**syntax**: *pk, err = pkey.new(config)*

**syntax**: *pk, err = pkey.new(string, format?)*

**syntax**: *pk, err = pkey.new()*

Creates a new pkey instance. The first argument can be:

1. A table which defaults to:

```lua
{
    type = 'RSA',
    bits = 2048,
    exp = 65537
}
```

to create EC private key:

```lua
{
    type = 'EC',
    curve = 'primve196v1',
}
```

2. A string of private or public key in PEM or DER format; optionally tells the library
to explictly decode the key using `format`, which can be a choice of `PER`, `DER` or `*`
for auto detect.
3. `nil` to create a 2048 bits RSA key.


### pkey:getParameters

**syntax**: *parameters, err = pk:getParameters()*

Returns a table containing the `parameters` of pkey instance. Currently only `n`, `e` and `d`
parameter of RSA key is supported. Each value of the returned table is a
[resty.openssl.bn](#restyopensslbn) instance.

```lua
local pk, err = require("resty.openssl").pkey.new()
local parameters, err = pk:getParameters()
local e = parameters.e
ngx.say(ngx.encode_base64(e:toBinary()))
-- outputs 'AQAB' (65537) by default
```

### pkey:sign

**syntax**: *signature, err = pk:sign(digest)*

Sign a [digest](#restyopenssldigest) using the private key defined in `pkey`
instance. The `digest` parameter must be a [resty.openssl.digest](#restyopenssldigest) 
instance. Returns the signed raw binary and error if any.

```lua
local pk, err = require("resty.openssl").pkey.new()
local digest, err = require("resty.openssl").digest.new("SHA256")
digest:update("dog")
local signature, err = pk:sign(digest)
ngx.say(ngx.encode_base64(signature))
```

### pkey:verify

**syntax**: *ok, err = pk:verify(signature, digest)*

Verify a signture (which can be generated by [pkey:sign](#pkey-sign)). The second
argument must be a [resty.openssl.digest](#restyopenssldigest) instance that uses
the same digest algorithm as used in `sign`.

### pkey:toPEM

**syntax**: *pem, err = pk:toPEM(private_or_public?)*

Outputs private key or public key of pkey instance in PEM format. `private_or_public`
must be a choice of `public`, `PublicKey`, `private`, `PrivateKey` or nil.
By default, it returns the public key.


## resty.openssl.bn

Module to expose BIGNUM structure. This module is not exposed through `resty.openssl`.

### bn.new

**syntax**: *b, err = bn.new(bn_instance or number?)*

Creates a BIGNUM instance. The first argument can be `BIGNUM *` cdata object, or a Lua number,
or `nil` to creates a empty instance.

### bn:toBinary

**syntax**: *bin, err = bn:toBinary()*

Export the BIGNUM value in binary.

```lua
local b, err = require("resty.openssl.bn").new(23333)
local bin, err = b:toBinary()
ngx.say(ngx.encode_base64(bin))
-- outputs "WyU="
```

## resty.openssl.digest

Module to interact with message digest.

### digest.new

**syntax**: *d, err = digest.new(digest_name)*

Creates a digest instance. The `digest_name` is a valid digest algorithm name. To view
a list of digest algorithms implemented, use `openssl list -digest-algorithms`

### digest:update

**syntax**: *digest:update(partial, ...)*

Updates the digest with one or more string.

### digest:final

**syntax**: *digest:update(partial?, ...)*


## resty.openssl.x509

## resty.openssl.x509.csr

## resty.openssl.x509.altname

## resty.openssl.x509.name


TODO
====

- test memory leak

[Back to TOC](#table-of-contents)


Copyright and License
=====================

This module is licensed under the BSD license.

Copyright (C) 2019, by fffonion <fffonion@gmail.com>.

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

[Back to TOC](#table-of-contents)

See Also
========
* [luaossl](https://github.com/wahern/luaossl)

[Back to TOC](#table-of-contents)