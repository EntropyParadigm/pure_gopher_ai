PureGopherAI - Static Content Guide
====================================

This directory serves static content via the Gopher protocol.

Gophermap Format
----------------
Each line in a gophermap file follows this format:

  TYPE DISPLAY_TEXT <TAB> SELECTOR <TAB> HOST <TAB> PORT

Types:
  0 - Text file
  1 - Directory/Menu
  7 - Search
  9 - Binary file
  i - Info line (non-selectable)
  h - HTML link
  g - GIF image
  I - Image (generic)

Example:
  0About this server	/about	localhost	70
  1Browse files	/files	localhost	70
  iThis is an info line

For info lines, you can omit selector/host/port:
  iJust some text to display

Directory Structure
-------------------
Place your content in ~/.gopher/ (or configure content_dir in config.exs)

  ~/.gopher/
  ├── gophermap          <- Root menu
  ├── README.txt         <- Text files
  ├── docs/
  │   ├── gophermap      <- Subdirectory menu
  │   └── guide.txt
  └── files/
      └── data.bin

Auto-generated Listings
-----------------------
If a directory doesn't have a gophermap, the server will auto-generate
a listing of its contents.

Tips
----
- Use 'i' type for headers and spacing
- Keep selectors simple and consistent
- Test with: echo "/files" | nc localhost 7070
