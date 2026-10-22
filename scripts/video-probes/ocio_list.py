import PyOpenColorIO as o
for uri in ("ocio://studio-config-latest",):
    c = o.Config.CreateFromFile(uri)
    print(uri, c.getName())
    print("colorspaces:", [cs.getName() for cs in c.getColorSpaces()][:60])
    for d in c.getDisplays(): print("display", d, list(c.getViews(d)))
