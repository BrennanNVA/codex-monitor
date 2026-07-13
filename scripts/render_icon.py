from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets"
SIZE = 512


def rounded_line(draw: ImageDraw.ImageDraw, points, fill, width):
    draw.line(points, fill=fill, width=width, joint="curve")
    radius = width // 2
    for x, y in points:
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=fill)


image = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(image)
draw.rounded_rectangle((24, 24, 488, 488), radius=104, fill="#0b1220", outline="#334155", width=16)
draw.rounded_rectangle((70, 96, 442, 416), radius=48, fill="#020617", outline="#164e63", width=12)
rounded_line(draw, [(150, 190), (220, 256), (150, 322)], "#22d3ee", 38)
rounded_line(draw, [(264, 322), (354, 322)], "#22d3ee", 38)
draw.ellipse((354, 78, 430, 154), fill="#0b1220")
draw.ellipse((366, 90, 418, 142), fill="#22c55e")

png_path = ASSETS / "codex-monitor.png"
ico_path = ASSETS / "codex-monitor.ico"
image.save(png_path, format="PNG", optimize=True)
image.save(ico_path, format="ICO", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print(png_path)
print(ico_path)
