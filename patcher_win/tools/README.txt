Place debugfs.exe (and its dependencies) in this directory.

debugfs is part of e2fsprogs. Windows builds can be obtained from:

  Option 1 (recommended): MSYS2
    pacman -S mingw-w64-x86_64-e2fsprogs
    Copy debugfs.exe from C:\msys64\mingw64\bin\

  Option 2: Pre-built binaries
    https://github.com/nicuveo/e2fsprogs-win32/releases

  Option 3: Build from source
    https://github.com/tytso/e2fsprogs
    Build with MSYS2/MinGW: ./configure && make

Required files (copy all to this directory):
  - debugfs.exe
  - libext2fs-2.dll (or similar, check with `ldd debugfs.exe` in MSYS2)
  - libcom_err-2.dll
  - libe2p-2.dll
  - libblkid-1.dll (if needed)

Test by running: debugfs.exe --version
