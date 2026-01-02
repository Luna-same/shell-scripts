case $- in
*i*) ;;
*) return ;;
esac
HISTCONTROL=ignoreboth

shopt -s histappend

HISTSIZE=1000
HISTFILESIZE=2000

shopt -s checkwinsize
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
  debian_chroot=$(cat /etc/debian_chroot)
fi

case "$TERM" in
xterm-color | *-256color) color_prompt=yes ;;
esac

if [ -n "$force_color_prompt" ]; then
  if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
    color_prompt=yes
  else
    color_prompt=
  fi
fi

unset color_prompt force_color_prompt

case "$TERM" in
xterm* | rxvt*)
  PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
  ;;
*) ;;
esac

# Add an "alert" alias for long running commands.  Use like so:
#   sleep 10; alert
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'

if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

source ~/complete_alias

if [ -x /usr/bin/dircolors ]; then
  test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
  alias l='ls --color=auto -lF'
  alias ll='ls --color=auto -lAF'
  alias grep='grep --color=auto'
fi

alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
alias tailf='tail -f'
alias d='docker'
alias dt='docker network'
alias da='docker ps -a'
alias ds='docker ps'
alias dl='docker logs'
alias dc='docker compose'
alias sc='systemctl'
alias scs='systemctl status'
alias sca='systemctl start'
alias vim="nvim"
alias kb='kubectl'
alias ja='journalctl'

alias proxy='export all_proxy=http://127.0.0.1:33333; echo "代理已开启 (Port: 33333)"'
alias unproxy='unset all_proxy; echo "代理已关闭"'

root() {
    if [ "$EUID" -ne 0 ]; then
        sudo -i
    fi
}

1000() {
    local target_u
    target_u=$(id -nu 1000 2>/dev/null)
    if [ -z "$target_u" ]; then
        echo "没有UID 为 1000 的用户"
        return 1
    fi

    if [ "$(whoami)" != "$target_u" ]; then
        sudo -i -u "$target_u"
    fi
}

complete -F _complete_alias d
complete -F _complete_alias sc
complete -F _complete_alias kb