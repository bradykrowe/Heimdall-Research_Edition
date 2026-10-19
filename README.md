# Heimdall Lab Edition (beta)

[![install](https://github.com/bradykrowe/Heimdall-Research_Edition/actions/workflows/install.yml/badge.svg)](https://github.com/bradykrowe/Heimdall-Research_Edition/actions/workflows/install.yml)

The badge is a clean-machine install on GitHub's macOS and Windows runners, with the
software step on; it cannot prove the GUI steps, the password prompt, a Mac without
Command Line Tools, or the lab's real sync client.

One installer that gives a working scientist a second brain: an Obsidian vault
with a folder tree for a lab, a set of thinking commands for Claude Code, and a
setup interview that teaches Claude who you are so every later session starts
there.

Everything lives on your machine. The vault is a folder of plain markdown. The
only thing that leaves the computer is the text of each conversation with
Claude, which goes to Anthropic to run the model. The bundle README inside the
zip says this again, in a table, before you install.

Each person in the lab gets a private vault. The lab shares one folder, `Lab/`,
that every person's Claude reads first for lab questions. Notes reach it only
through `/share-to-lab`, which shows the exact file and refuses anything private.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/lab_layer_dark.png">
  <img src="docs/img/lab_layer_light.png" width="100%" alt="Five private vaults, one per role: PI, postdoc, graduate student, staff or core director, undergraduate or rotation. Notes reach the shared Lab/ folder only through /share-to-lab, which refuses People/, Journal/, System/, private notes and notes that name a lab member. Every Claude reads Lab/.">
</picture>

## Install

You need a Claude account with Claude Code: a Pro, Max or Team seat, or an
API key. The installer asks you to sign in the first time Claude Code starts.

### macOS

Paste this into Terminal. It downloads the release, checks its hash, unpacks
it and starts the installer. Read [get.sh](get.sh) first if you like; it is
short and commented.

```bash
curl -fsSL https://raw.githubusercontent.com/bradykrowe/Heimdall-Research_Edition/v0.1.0-beta/get.sh | bash
```

If your Mac is managed and you are not an administrator, the script says so and
stops before installing anything. Ask IT to install Obsidian, Node.js, Python
3.12 and Claude Code, then run the same line with `bash -s -- --skip-software`
on the end.

### Windows

Paste this into PowerShell. Read [get.ps1](get.ps1) first if you like.

```powershell
irm https://raw.githubusercontent.com/bradykrowe/Heimdall-Research_Edition/v0.1.0-beta/get.ps1 | iex
```

If Windows shows a SmartScreen warning, that is because the scripts are not
code-signed. Choose More info, then Run anyway.

### By hand

Download the zip and its `.sha256` from the
[latest release](https://github.com/bradykrowe/Heimdall-Research_Edition/releases/latest),
check the hash, unzip, and double click `Install_Heimdall.cmd` (Windows) or
`Install_Heimdall.command` (macOS). The README inside the zip covers the
Gatekeeper and SmartScreen prompts.

## After the install

1. Open the vault in Obsidian and turn on the Local REST API plugin. Paste its
   key into `System/secrets/obsidian.env`. The installer wired everything else.
2. Open the vault folder in the Claude desktop app, Code tab, and type
   `/bootstrap`. The first five questions take five minutes.
3. Drop one PDF into `Literature/` and run `/paper`.

`START_HERE.md` in the vault walks through all three.

## What is in the zip

| Part | What |
|---|---|
| `Install_Heimdall.ps1`, `install_heimdall.sh` | The installers, plain text, commented |
| `payload/vault/` | The starter vault: Lab, Literature, Projects, Manuscripts, Grants, Teaching, Service, People and the system folders, with templates |
| `payload/claude/commands/` | 23 thinking commands, including `/paper`, `/protocol` and `/today` |
| `payload/claude/skills/` | 8 skills |
| `manifest/plugins.json` | The Obsidian plugins, by tier, with a reason for each |

## Beta

This is a beta for one research group. The Windows path has been run end to
end. On macOS the vault, plugin and connector steps have been run on real
hardware; the software step (Homebrew, Node, Python, Claude Code) has not yet
been run on an Apple silicon Mac. The full list of known limits is in the
bundle README.

Updates arrive as a new tagged release. Until the update command ships, a new
release installs over the old one by pointing the installer at your existing
vault: it adds what is missing and never overwrites a file you have.

## Reporting a problem

Open an issue with the failing command and its output. Never paste vault text,
a key, or anything from `System/secrets/`. The tool runs locally; nobody needs
your vault to debug it.

## Data

Human-subjects data, patient material, donor information and anything under an
IRB protocol or a data use agreement should never be in the vault. The starter
configuration says so and the vault holds pointers, not data.

## License

Source available for use inside your own research group. See
[LICENSE.md](LICENSE.md).
