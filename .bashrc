source ~/complete_alias

alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
alias tailf='tail -f'
alias l='ls -la'
alias ll='ls -l'
alias d='docker'
alias dt='docker network'
alias da='docker ps -a'
alias ds='docker ps'
alias dc='docker compose'
alias sc='systemctl'
alias scs='systemctl status'
alias sca='systemctl start'
alias vim="nvim"
alias kb='kubectl'

alias proxy='export all_proxy=http://127.0.0.1:33333; echo "代理已开启 (Port: 33333)"'
alias unproxy='unset all_proxy; echo "代理已关闭"'

complete -F _complete_alias d
complete -F _complete_alias sc
complete -F _complete_alias kb