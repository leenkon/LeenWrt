#!/usr/bin/env python3
"""OAF 特征库工具：feature.bin 校验、列表、抓取。

特征库格式（上游 open-app-filter/src/fwx_feature.c，密钥随源码公开）：
  24B 头 | magic "FWXB" | fmt=1 | alg=1(XTEA-CTR) | hdr_size=16b | plain_len=32b | crc32=32b | nonce=64b  (全 LE)
  负载   | 明文经 XTEA-CTR 加密，keystream = XTEA(nonce+i)，i 为 8 字节块序号（64 位递增，勿截断成 32 位）
  明文   | 特征文本行（含 #version / #format / `id~name:[...]`）；crc32 校验失败即视为损坏

OAF 守护进程(oafd)启动即解密 /etc/fwxd/feature.bin 并装载，无需任何格式转换——
本工具只负责从官方 API 取最新 feature.bin（免费档 token=0、free=1 包）并校验，直接投喂。

子命令：verify / list / fetch
仅依赖标准库；在 CI/host 运行即可。
"""
import argparse
import hashlib
import json
import os
import re
import struct
import sys
import tarfile
import urllib.request
from urllib.parse import urlencode
import zlib

KEY = (0x8F4C29A1, 0x73B6D502, 0xC14E87F3, 0x2AD95B60)
DELTA = 0x9E3779B9
MASK = 0xFFFFFFFF
MAGIC = b'FWXB'
HDR = 24
FMT_VER, ALG_XTEA_CTR = 1, 1
MAX_SIZE = 20 * 1024 * 1024

API_BASE = 'https://api.openappfilter.com'
API_VERSION = 'v4.0'


def enc_block(v0, v1):
    s = 0
    for _ in range(32):
        v0 = (v0 + ((((v1 << 4) ^ (v1 >> 5)) + v1) ^ (s + KEY[s & 3]))) & MASK
        s = (s + DELTA) & MASK
        v1 = (v1 + ((((v0 << 4) ^ (v0 >> 5)) + v0) ^ (s + KEY[(s >> 11) & 3]))) & MASK
    return v0, v1


def ctr_crypt(data: bytes, nonce: int) -> bytes:
    out = bytearray(len(data))
    off, counter = 0, nonce
    while off < len(data):
        v0, v1 = enc_block(counter & MASK, (counter >> 32) & MASK)
        stream = struct.pack('<II', v0, v1)
        for b in stream:
            if off >= len(data):
                break
            out[off] = data[off] ^ b
            off += 1
        counter += 1  # 64 位递增：mask 成 32 位会让第 2 块起解密错乱
    return bytes(out)


def unpack(path: str) -> bytes:
    """读取并解密 feature.bin，返回明文；失败抛 ValueError"""
    raw = open(path, 'rb').read()
    if len(raw) < HDR or raw[:4] != MAGIC:
        raise ValueError('不是 feature.bin（magic 应为 FWXB）')
    if raw[4] != FMT_VER or raw[5] != ALG_XTEA_CTR or struct.unpack_from('<H', raw, 6)[0] != HDR:
        raise ValueError('不支持的头版本 fmt=%d alg=%d' % (raw[4], raw[5]))
    plain_len, crc = struct.unpack_from('<II', raw, 8)
    nonce = struct.unpack_from('<Q', raw, 16)[0]
    if plain_len == 0 or plain_len > MAX_SIZE or len(raw) != HDR + plain_len:
        raise ValueError('长度字段与文件不符 plain_len=%d file=%d' % (plain_len, len(raw)))
    plain = ctr_crypt(raw[HDR:], nonce)
    if (zlib.crc32(plain) & MASK) != crc:
        raise ValueError('CRC 校验失败，特征库已损坏或密钥不匹配')
    return plain


def meta(plain: bytes) -> dict:
    txt = plain.decode('utf-8', 'replace')
    info = {'version': '', 'format': '', 'apps': 0, 'classes': 0}
    for line in txt.replace('\r\n', '\n').split('\n'):
        if line.startswith('#version '):
            info['version'] = line[9:].strip()
        elif line.startswith('#format '):
            info['format'] = line[8:].strip()
        elif line.startswith('#class '):
            info['classes'] += 1
        elif line and not line.startswith('#') and ':' in line:
            info['apps'] += 1
    return info


def do_verify(a):
    plain = unpack(a.path)
    info = meta(plain)
    print('OK  crc 校验通过')
    print('  version : %s' % info['version'])
    print('  format  : %s' % info['format'])
    print('  特征条目 : %d' % info['apps'])
    print('  分类数   : %d' % info['classes'])
    print('  明文字节 : %d' % len(plain))
    return 0


def device_id():
    for ifname in ('br-lan', 'eth0', 'eth1'):
        p = '/sys/class/net/%s/address' % ifname
        if os.path.exists(p):
            mac = re.sub(r'[^0-9a-fA-F]', '', open(p).read()).lower()
            if len(mac) == 12:
                return hashlib.md5(mac.encode()).hexdigest()
    return ''


def device_model():
    try:
        board = json.load(open('/etc/board.json'))
        return board['model']['name']
    except Exception:
        pass
    for p in ('/proc/device-tree/model', '/tmp/sysinfo/board_name'):
        if os.path.exists(p):
            return open(p).read().strip().replace('\x00', '')
    return 'x86_64'


def api_get(path, params):
    url = '%s%s?%s' % (API_BASE, path, urlencode(params))
    req = urllib.request.Request(url, headers={'User-Agent': 'leanwrt-feature-tool/1.0'})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode('utf-8'))


def get_feature_list(token, did=None, model=None):
    """官方 /api/get_feature_list；token 留空即视为 0（免费档，UI 里 key 不填发的值）"""
    data = api_get('/api/get_feature_list', {
        'token': token or '0',
        'device_id': did or device_id() or 'leanwrt-build',
        'model': model or device_model(),
        'version': API_VERSION,
    })
    if data.get('code') != 20000:
        raise ValueError('获取特征库列表失败: code=%s %s' % (data.get('code'), data.get('msg')))
    return data['data']


def pick_free(files):
    free = [f for f in files if f.get('free') == 1]
    if not free:
        raise ValueError('特征库列表中没有免费(free=1)包；需订阅 token 或手动指定 --id')
    free.sort(key=lambda f: (f.get('count', 0), f.get('size', 0)), reverse=True)
    return free[0]


def do_list(a):
    data = get_feature_list(a.token)
    print('版本=%s 语言=%s 包数=%s' % (data.get('version'), data.get('lang'), data.get('count')))
    for f in data['files']:
        tag = '免费' if f.get('free') == 1 else '订阅'
        print('  id=%-8s ver=%-8s 应用=%-4s 大小=%-7s [%s] %s' % (
            f['id'], f['version'], f['count'], f['size'], tag, f.get('type', '')))
    return 0


def do_fetch(a):
    """抓取最新 feature.bin：官方 API 免费档（token=0，自动选 free=1 包，含图标）。
    解出 feature.bin 即可直接投喂 OAF 守护进程，无需任何格式转换。"""
    token = a.token or '0'
    if not a.id:
        pkg = pick_free(get_feature_list(token, a.device_id, a.model)['files'])
        a.id = pkg['id']
        print('选定免费特征库 id=%s ver=%s 应用=%s' % (pkg['id'], pkg['version'], pkg['count']))
    did = a.device_id or device_id() or 'leanwrt-build'
    params = {'token': token, 'device_id': did,
              'model': a.model or device_model(), 'version': API_VERSION, 'id': a.id}
    if a.lang:
        params['lang'] = a.lang
    url = '%s/api/download_feature?%s' % (API_BASE, urlencode(params))
    print('拉取 %s' % url)
    data = urllib.request.urlopen(url, timeout=a.timeout).read()

    if data[:2] == b'\x1f\x8b':  # tar.gz：feature.bin + app_icons/
        import io
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as tf:
            members = {m.name.lstrip('./'): m for m in tf.getmembers()}
        if 'feature.bin' not in members:
            sys.exit('特征包缺少 feature.bin，条目：%s' % sorted(members)[:10])
        open(a.out, 'wb').write(tf.extractfile(members['feature.bin']).read())
        print('已解出 feature.bin → %s' % a.out)
        if a.icons:
            os.makedirs(a.icons, exist_ok=True)
            n = 0
            for name, m in members.items():
                if name.startswith('app_icons/') and m.isfile() and os.path.basename(name):
                    with open(os.path.join(a.icons, os.path.basename(name)), 'wb') as f:
                        f.write(tf.extractfile(m).read())
                    n += 1
            print('已解出图标 %d 个 → %s' % (n, a.icons))
    else:
        open(a.out, 'wb').write(data)
        print('已保存 %s' % a.out)

    info = meta(unpack(a.out))
    print('version=%s format=%s 条目=%d' % (info['version'], info['format'], info['apps']))
    return 0


def main():
    p = argparse.ArgumentParser(description='OAF 特征库（feature.bin）校验与更新工具')
    sub = p.add_subparsers(dest='cmd', required=True)

    v = sub.add_parser('verify', help='校验 feature.bin 并打印元信息')
    v.add_argument('path'); v.set_defaults(func=do_verify)

    f = sub.add_parser('list', help='列出官方特征库（token=0 即免费档，无需 key）')
    f.add_argument('--token', help='订阅 token；留空=免费档')
    f.add_argument('--model', help='设备型号，默认自动探测')
    f.add_argument('--device-id', help='设备指纹，默认 leanwrt-build')
    f.set_defaults(func=do_list)

    f = sub.add_parser('fetch', help='抓取最新 feature.bin（默认官方免费档，token=0）')
    f.add_argument('-o', '--out', default='feature.bin')
    f.add_argument('--token', help='官方订阅 token（免费档留空即可）')
    f.add_argument('--id', help='指定包 id（订阅包；免费档自动解析）')
    f.add_argument('--lang', help='语言(zh/cn)；免费档建议留空避免接口拒')
    f.add_argument('--model', help='设备型号，默认自动探测')
    f.add_argument('--device-id', help='设备指纹，默认 leanwrt-build')
    f.add_argument('--icons', help='包内含图标时解包到该目录（扁平 <appId>.png）')
    f.add_argument('--timeout', type=int, default=300)
    f.set_defaults(func=do_fetch)

    a = p.parse_args()
    return a.func(a)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except ValueError as e:
        sys.exit('错误: %s' % e)
