from . import appinfo, compat, config, libraries, licensecache, packageinfo, vdf

for _m in (appinfo, compat, config, libraries, licensecache, packageinfo):
    _m.vdf = vdf
del _m
