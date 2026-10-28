(LLM-authored slop README)

# git-elsewhere

Syncthing syncs these repositories' `.git` directories along with their files,
so when two hosts both run git in one, each host's writes overwrite the other's.
For example, a `git status` on one host rewrites `.git/index` in passing, and
Syncthing then copies that index over a commit just made on another host.

`git-elsewhere` makes one host, `target_hostname`, the only one that runs git
in them. On every other host, it stands in for `git` and `clank-right` and runs
them on the target over ssh, in the same directory, with the same arguments,
input, and output:

- `git`, when it would work inside a Syncthing folder: its directory, after
  any `-C` options, or a repository or work tree named by `--git-dir`,
  `--work-tree`, `GIT_DIR`, or `GIT_WORK_TREE`, holds a `.stfolder` or is below
  one. Elsewhere, it runs the real `git` right here.
- `clank-right`, always, since it works on the synced repositories in its
  `projects.txt` wherever it runs from. It writes `AGENTS.md` and commits it at
  once, which only works on the host whose git does the committing.

On `target_hostname` itself, both run the real command.

## Setup

On each host, `~/.config/git-elsewhere/config` (or under `$XDG_CONFIG_HOME`):

	target_hostname="xclank"

It must match what `hostname` prints on the target, and `ssh xclank` must work
without a prompt. On the hosts other than the target, link the script in as
both commands, in a directory ahead of the real ones on `PATH`:

	ln -s ~/code/system/git-elsewhere/git-elsewhere ~/bin/git
	ln -s ~/code/system/git-elsewhere/git-elsewhere ~/bin/clank-right

On the target, the forwarded command runs with `$HOME/bin` first on `PATH`, so
that's where the real `clank-right` has to be.

## Behaviour to know about

- **Syncthing's delay.** The target sees this host's edits only once Syncthing
  has delivered them, about 1–2 s later, so a `git add` or `git commit` right
  after an edit can miss it; and changes that git makes to files (`checkout`,
  `reset`, `stash`, `rebase`) reach this host 1–2 s after the command returns.
  An edit made here in that window turns into a Syncthing conflict copy.
- **Paths** must be the same on both hosts, with symlinks resolved. The
  directory a command runs from has to exist on the target too, and files
  named in arguments, like `git commit -F /tmp/msg`, are read and written
  there.
- **Environment.** Exported `GIT_` variables (e.g. `GIT_EDITOR`) go along,
  except `GIT_EXEC_PATH`, which points into this host's git; nothing else does.
  One that names a program here, like VS Code's `GIT_ASKPASS`, has to work on
  the target too.
- **Input.** Like any ssh, a forwarded command reads its input even when it
  doesn't need it, so in a `while read` loop, run it with `</dev/null`. It
  doesn't read a terminal, though, unless it gets one (next).
- **Terminals.** When input, output, and errors are all a terminal, ssh gets
  one too, for the pager, the editor, and prompts. Without one, Ctrl-C stops
  ssh, but not the command on the target.
- **Speed.** The ssh connection stays open for 10 minutes after use, so a
  forwarded command takes ~15 ms instead of ~100 ms.
- **Failures.** If ssh fails, so does the command, with status 255, rather than
  running here and bringing back the writes from two hosts; it gives up after
  10 s without an answer. The script's own errors, such as a missing config or
  a directory missing on the target, exit with 128, like git's fatal errors.
- **What isn't covered.** Tools that read or write `.git` without running our
  `git` (libgit2, gitoxide, git's hooks and `!` aliases, which find git's own
  directory first on `PATH`), and `git init` or `git clone` into a Syncthing
  folder from outside one, still work here.

## Development

	zsh tests/run.zsh
