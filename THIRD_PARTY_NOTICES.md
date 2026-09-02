# Third-Party Notices

## Bifrost

CC Buddy includes `bifrost-http` v1.6.11 from
[`Bifrost`](https://github.com/maximhq/bifrost/tree/2d9a35e30ee1659ec217a22b1f33621856afd431),
licensed under the Apache License 2.0. The license is included as
`Bifrost-LICENSE.txt`.

CC Buddy modifies the upstream x86_64 executable before code signing. The
modification corrects only its Mach-O `LC_VERSION_MIN_MACOSX` SDK field from
10.4 to the upstream cross-compiler's actual MacOSX12.3.sdk; the 10.4 deployment
target and Bifrost source code are unchanged.

The executable includes the BSD-3-Clause portions of
[`github.com/cyphar/filepath-securejoin` v0.6.1](https://github.com/cyphar/filepath-securejoin/tree/9c4135bad38a4e2cda5220216000130d25b2e190):

Copyright (C) 2014-2015 Docker Inc & Go Authors. All rights reserved.
Copyright (C) 2017-2024 SUSE LLC. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.
- Neither the name of Google Inc. nor the names of its contributors may be
  used to endorse or promote products derived from this software without
  specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

The executable also contains the unmodified
[`github.com/hashicorp/go-version` v1.8.0](https://github.com/hashicorp/go-version/tree/505335eb9df1a0063c4f4edadabbd4ba68a6039c)
component (MPL-2.0; copyright IBM Corp. 2014, 2025). Its Source Code Form is
available at the immutable version link and remains governed by the
[Mozilla Public License 2.0](https://www.mozilla.org/MPL/2.0/). Nothing in CC
Buddy's license limits recipients' rights in that Source Code Form under
MPL-2.0.

## Skills Hub

The Skills workspace is derived from the product behavior and interface of
[`skills-hub`](https://github.com/qufei1993/skills-hub), used under the MIT
License.

Copyright (c) 2026 Skills Hub contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
