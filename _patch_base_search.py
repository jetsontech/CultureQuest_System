from pathlib import Path

path = Path(r".\app\templates\base.html")
text = path.read_text(encoding="utf-8")

if 'url_for(\'public.search_channels\')' not in text and 'url_for("public.search_channels")' not in text:
    nav_marker = '<a href="{{ url_for(\'public.epg\') }}">Guide</a>'
    replacement = nav_marker + '\n        <a href="{{ url_for(\'public.search_channels\') }}">Search</a>'
    text = text.replace(nav_marker, replacement)

if 'class="topbar-search"' not in text:
    marker = '</nav>'
    inject = '''
      <form class="topbar-search" method="get" action="{{ url_for('public.search_channels') }}">
        <input type="text" name="q" placeholder="Search">
      </form>
'''
    text = text.replace(marker, marker + inject, 1)

path.write_text(text, encoding="utf-8")
print("Patched base.html with search.")
