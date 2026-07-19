# Third-party components

## CVS (bundled binary)

MacCVS bundles a copy of the **CVS 1.11.23** command-line client inside the app
(`MacCVS.app/Contents/Resources/cvs`) so users don't have to install one. It is
invoked as a separate program (via `exec`), not linked into the app.

- **Upstream source:** GNU CVS 1.11.23 —
  <https://ftp.gnu.org/non-gnu/cvs/source/stable/1.11.23/cvs-1.11.23.tar.bz2>
- **License:** GNU General Public License v2 or later (see the CVS distribution's
  `COPYING`).
- **How the bundled binary is produced:** by `build-cvs.sh` in this repository,
  which downloads the unmodified upstream source and applies two small
  modern-toolchain fixes (documented in the script) before building a universal
  binary configured with `--without-gssapi --disable-encryption`. The resulting
  binary links only `/usr/lib/libSystem.B.dylib`.

To obtain or rebuild the exact CVS source used, run `./build-cvs.sh`, or download
the upstream tarball above.

## swifty-diff (source adaptation)

The diff viewer's data model and side-by-side visual style are adapted from
[swifty-diff / GitDiffViewer](https://github.com/michaelneale/swifty-diff) by
Michael Neale, used under the MIT License.
