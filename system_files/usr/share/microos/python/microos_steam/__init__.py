from . import appinfo, compat, config, libraries, vdf

for _m in (appinfo, compat, config, libraries):
    _m.vdf = vdf
del _m
