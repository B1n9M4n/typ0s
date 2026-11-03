# dmgbuild layout for the typ0s install window: the app on the left, Applications on the right,
# over the retro background (640 x 350 points, with a @2x version inside the TIFF)
app = defines['app']
files = [app]
symlinks = {'Applications': '/Applications'}
background = defines['background']
window_rect = ((200, 120), (640, 350))
icon_size = 96
text_size = 12
show_status_bar = False
show_toolbar = False
show_sidebar = False
icon_locations = {'typ0s.app': (165, 197), 'Applications': (475, 197)}
format = 'UDZO'
