#!/usr/bin/env -S zsh -f
# Model-output: Claude Opus 5.5
#
# Tests for git-elsewhere, with stand-ins for ssh and for the real git and
# clank-right. The stand-in ssh runs the command it's given right here, in a
# zsh with an empty environment apart from $PATH and a $HOME whose bin holds
# the target host's stand-ins, so the commands log
# whether they ran "here" or "there", in which directory, with which
# arguments and GIT_ variables.
#
#	zsh tests/run.zsh
#
# Exits 0 iff every check passed.

emulate -R zsh
setopt no_unset

typeset -g  ROOT=${0:A:h:h}
typeset -g  WORK=${$(mktemp -d):A}
typeset -g  LOG=$WORK/log
typeset -gi CHECKS=0 FAILS=0

# Records one check.
# $1: what should hold
# $2: what happened
# $3: what should have happened
check() {
	(( ++CHECKS ))
	if [[ $2 == "$3" ]]; then
		print -r -- "  ok: $1"
	else
		(( ++FAILS ))
		print -r -- "FAIL: $1"
		print -r -- "--- got:"
		print -r -- $2
		print -r -- "--- expected:"
		print -r -- $3
	fi
}

# Writes a stand-in for the real git and clank-right.
# $1: its path
# $2: what it logs as where it ran
write_standin() {
	print -r -- "#!/usr/bin/env -S zsh -f
print -r -- \"$2 \${0:t} in \${PWD:A}: [\${(j: :)\${(@qq)@}}]\" >> ${(qq)LOG}
for var in \${(ko)parameters[(I)GIT_*]}; do
	print -r -- \"  \$var=\${(P)var}\" >> ${(qq)LOG}
done
if (( \${@[(I)--stdin]} )); then
	print -r -- \"  stdin: \$(cat)\" >> ${(qq)LOG}
fi
exit \${GIT_STANDIN_EXIT:-0}" > $1
	chmod +x $1
}

# Lays out $WORK: this host's PATH, the target's $HOME, a Syncthing folder, a
# plain directory, and the config.
set_up() {
	mkdir -p $WORK/{bin,real,there/bin,config/git-elsewhere,synced/.stfolder,synced/repo/sub,plain}
	ln -s $WORK/synced/repo/sub $WORK/plain/link
	ln -s $ROOT/git-elsewhere $WORK/bin/git
	ln -s $ROOT/git-elsewhere $WORK/bin/clank-right
	ln -s $ROOT/git-elsewhere $WORK/bin/git-elsewhere
	local name
	for name in git clank-right; do
		write_standin $WORK/real/$name here
		write_standin $WORK/there/bin/$name there
	done
	print -r -- "#!/usr/bin/env -S zsh -f
tty=-T
if (( \${@[(I)-t]} )); then
	tty=-t
fi
print -r -- \"ssh to \${@[\${@[(i)--]} + 1]} (\$tty)\" >> ${(qq)LOG}
# Makes a directory missing on the target
if [[ -n \${STANDIN_GONE-} ]]; then
	rmdir \$STANDIN_GONE
fi
exec env -i HOME=${(qq)WORK}/there PATH=\"\$PATH\" zsh -fc \"\${@[-1]}\"" > $WORK/bin/ssh
	chmod +x $WORK/bin/ssh
	write_target target-host

	unset -m 'GIT_*'
	export PATH=$WORK/bin:$WORK/real:$PATH
	export XDG_CONFIG_HOME=$WORK/config
}

# $1: the config file's contents, with \n for newlines
write_config() {
	print -- $1 > $WORK/config/git-elsewhere/config
}

# Writes a config, with comments and spaces, that names a target host.
# $1: the target's name, or "this host" for the host the tests run on
write_target() {
	local target=$1
	if [[ $target == "this host" ]]; then
		target=$(</proc/sys/kernel/hostname)
	fi
	write_config "# Where git runs\n\ntarget_hostname = \"$target\""
}

# Runs a command with no input, and sets REPLY to what the stand-ins logged,
# then its output, then its exit status.
# $1: the directory to run it in, relative to $WORK
# $2...: the command, e.g. `env GIT_DIR=x git status`
run() {
	local dir=$1
	shift
	: > $LOG
	(
		cd $WORK/$dir
		"$@" < /dev/null >> $LOG 2>&1
		print -r -- "exit $?" >> $LOG
	)
	REPLY=$(<$LOG)
}

test_git() {
	run plain git log --oneline 'a b'
	check "outside a Syncthing folder, git runs here" $REPLY \
"here git in $WORK/plain: ['log' '--oneline' 'a b']
exit 0"

	run synced/repo/sub git commit -m "it's \$HOME" '' $'two\nlines' '*'
	check "in a Syncthing folder, git runs there, in the same directory and with the same arguments" $REPLY \
"ssh to target-host (-T)
there git in $WORK/synced/repo/sub: ['commit' '-m' 'it'\\''s \$HOME' '' 'two
lines' '*']
  GIT_ELSEWHERE_FORWARDED=1
exit 0"

	run synced git
	check "git with no arguments runs there too" $REPLY \
"ssh to target-host (-T)
there git in $WORK/synced: []
  GIT_ELSEWHERE_FORWARDED=1
exit 0"

	write_target "this host"
	run synced git status
	write_target target-host
	check "on target_hostname, git runs here" $REPLY \
"here git in $WORK/synced: ['status']
exit 0"

	run synced env GIT_ELSEWHERE_FORWARDED=1 git status
	check "git that was already forwarded runs here" $REPLY \
"here git in $WORK/synced: ['status']
  GIT_ELSEWHERE_FORWARDED=1
exit 0"
}

test_git_options() {
	run plain git -c alias.st=status -C ../synced -C '' -C repo st -C x
	check "global -C options say where git works, and they go along unchanged" $REPLY \
"ssh to target-host (-T)
there git in $WORK/plain: ['-c' 'alias.st=status' '-C' '../synced' '-C' '' '-C' 'repo' 'st' '-C' 'x']
  GIT_ELSEWHERE_FORWARDED=1
exit 0"

	run plain/link git -C .. status
	check "a -C .. goes up from where a symlink leads, as chdir does" $REPLY \
"ssh to target-host (-T)
there git in $WORK/synced/repo/sub: ['-C' '..' 'status']
  GIT_ELSEWHERE_FORWARDED=1
exit 0"

	run plain git --attr-source HEAD --shallow-file x -C ../synced status
	check "the values of --attr-source and --shallow-file aren't taken for the subcommand" $REPLY \
"ssh to target-host (-T)
there git in $WORK/plain: ['--attr-source' 'HEAD' '--shallow-file' 'x' '-C' '../synced' 'status']
  GIT_ELSEWHERE_FORWARDED=1
exit 0"

	run synced/repo git --bare -C ../../plain status
	check "--bare takes the directory before a later -C as the repository" $REPLY \
"ssh to target-host (-T)
there git in $WORK/synced/repo: ['--bare' '-C' '../../plain' 'status']
  GIT_ELSEWHERE_FORWARDED=1
exit 0"

	run plain git log -C ../synced
	check "a -C after the subcommand is the subcommand's" $REPLY \
"here git in $WORK/plain: ['log' '-C' '../synced']
exit 0"

	run plain git --git-dir=../synced/repo/.git status
	check "a --git-dir in a Syncthing folder sends git there" $REPLY \
"ssh to target-host (-T)
there git in $WORK/plain: ['--git-dir=../synced/repo/.git' 'status']
  GIT_ELSEWHERE_FORWARDED=1
exit 0"

	run plain git --work-tree ../synced/repo status
	check "so does a --work-tree" $REPLY \
"ssh to target-host (-T)
there git in $WORK/plain: ['--work-tree' '../synced/repo' 'status']
  GIT_ELSEWHERE_FORWARDED=1
exit 0"

	run plain env GIT_DIR=$WORK/synced/repo/.git git status
	check "so does GIT_DIR, which goes along" $REPLY \
"ssh to target-host (-T)
there git in $WORK/plain: ['status']
  GIT_DIR=$WORK/synced/repo/.git
  GIT_ELSEWHERE_FORWARDED=1
exit 0"
}

test_local_subcommands() {
	write_config 'target_hostname="target-host"\nlocal_subcommands=" push\tfetch "'
	run plain git -c push.default=current -C ../synced push origin
	check "a subcommand in local_subcommands runs here, even in a Syncthing folder" $REPLY \
"here git in $WORK/plain: ['-c' 'push.default=current' '-C' '../synced' 'push' 'origin']
exit 0"

	run synced git log push
	check "only the subcommand counts, not the arguments after it" $REPLY \
"ssh to target-host (-T)
there git in $WORK/synced: ['log' 'push']
  GIT_ELSEWHERE_FORWARDED=1
exit 0"

	run synced git -c alias.p=push p
	check "an alias of a local subcommand still runs there" $REPLY \
"ssh to target-host (-T)
there git in $WORK/synced: ['-c' 'alias.p=push' 'p']
  GIT_ELSEWHERE_FORWARDED=1
exit 0"

	run plain clank-right push
	write_target target-host
	check "local_subcommands are git's, not clank-right's" $REPLY \
"ssh to target-host (-T)
there clank-right in $WORK/plain: ['push']
  GIT_ELSEWHERE_FORWARDED=1
exit 0"
}

test_forwarding() {
	run synced env GIT_EDITOR=true GIT_EXEC_PATH=/nowhere GIT_STANDIN_EXIT=3 git commit
	check "exported GIT_ variables go along, except GIT_EXEC_PATH, and the exit status comes back" $REPLY \
"ssh to target-host (-T)
there git in $WORK/synced: ['commit']
  GIT_EDITOR=true
  GIT_ELSEWHERE_FORWARDED=1
  GIT_STANDIN_EXIT=3
exit 3"

	run plain env GIT_STANDIN_EXIT=4 git status
	check "the exit status comes back from git here too" $REPLY \
"here git in $WORK/plain: ['status']
  GIT_STANDIN_EXIT=4
exit 4"

	: > $LOG
	(cd $WORK/synced && print -r -- 'some input' | git hash-object --stdin)
	check "input goes along" "$(<$LOG)" \
"ssh to target-host (-T)
there git in $WORK/synced: ['hash-object' '--stdin']
  GIT_ELSEWHERE_FORWARDED=1
  stdin: some input"
}

test_clank_right() {
	run plain clank-right check
	check "clank-right runs there even outside a Syncthing folder" $REPLY \
"ssh to target-host (-T)
there clank-right in $WORK/plain: ['check']
  GIT_ELSEWHERE_FORWARDED=1
exit 0"

	write_target "this host"
	run plain clank-right update .
	write_target target-host
	check "on target_hostname, clank-right runs here" $REPLY \
"here clank-right in $WORK/plain: ['update' '.']
exit 0"
}

test_errors() {
	run plain git-elsewhere status
	check "run under its own name, it refuses" $REPLY \
"git-elsewhere: run this through a symlink named git or clank-right, not as git-elsewhere
exit 128"

	mkdir $WORK/synced/gone
	run synced/gone env STANDIN_GONE=$WORK/synced/gone git diff --quiet
	check "a directory missing there is a fatal error, not git's status 1" $REPLY \
"ssh to target-host (-T)
zsh:cd:1: no such file or directory: $WORK/synced/gone
exit 128"

	mkdir $WORK/synced/gone
	: > $LOG
	(cd $WORK/synced/gone && rmdir $WORK/synced/gone && git status >> $LOG 2>&1)
	check "a working directory that's gone here leaves git to complain here" "$(grep -c '^ssh' $LOG; grep -c '^here git' $LOG)" "0
1"

	rm $WORK/config/git-elsewhere/config
	run plain git status
	check "without a config, git outside a Syncthing folder still runs here" $REPLY \
"here git in $WORK/plain: ['status']
exit 0"

	run synced git status
	check "without a config, git in a Syncthing folder fails instead of running here" $REPLY \
"git-elsewhere: can't read $WORK/config/git-elsewhere/config, which should have a line like target_hostname=\"xclank\"
exit 128"

	write_config 'target_hostname=xclank'
	run synced git status
	check "a value must be quoted" $REPLY \
"git-elsewhere: $WORK/config/git-elsewhere/config:1: expected name=\"value\", not: target_hostname=xclank
exit 128"

	write_config 'target_hostname="target-host"\ntarget_port="22"'
	run synced git status
	check "an unknown setting is an error" $REPLY \
"git-elsewhere: $WORK/config/git-elsewhere/config:2: unknown setting target_port
exit 128"

	write_config 'target_hostname="target-host"\nlocal_subcommands="push, fetch"'
	run synced git status
	check "local_subcommands must be separated by spaces" $REPLY \
"git-elsewhere: $WORK/config/git-elsewhere/config:2: expected git subcommands separated by spaces, not: push,
exit 128"

	write_config '# nothing'
	run synced git status
	check "target_hostname is required" $REPLY \
"git-elsewhere: $WORK/config/git-elsewhere/config doesn't set target_hostname
exit 128"
}

main() {
	set_up
	test_git
	test_git_options
	test_local_subcommands
	test_forwarding
	test_clank_right
	test_errors
	rm -rf $WORK
	print -r -- "$CHECKS checks, $FAILS failed"
	(( FAILS == 0 ))
}

main
