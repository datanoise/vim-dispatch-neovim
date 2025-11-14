if exists('g:autoloaded_dispatch_neovim')
  finish
endif

let g:autoloaded_dispatch_neovim = 1

function! s:UsesTerminal(request)
  return a:request.action ==# 'start' ||
        \(a:request.action ==# 'make' && !a:request.background)
endfunction

function! s:NeedsOutput(request)
  return a:request.action ==# 'make'
endfunction

function! s:IsBackgroundJob(request)
  return a:request.action ==# 'make' && a:request.background
endfunction

function! s:CommandOptions(request) abort
  let l:opts = {
        \ 'name': a:request.title,
        \ 'background': a:request.background,
        \ 'request': a:request,
        \}
  let l:terminal_opts = { 'pty': 1, 'width': 999, 'height': 25 }

  if s:UsesTerminal(a:request)
    call extend(l:opts, l:terminal_opts)
  endif

  if s:NeedsOutput(a:request)
    " if s:IsBackgroundJob(a:request)
    call extend(l:opts, {
          \ 'on_stdout': function('s:BufferOutput'),
          \ 'on_stderr': function('s:BufferOutput'),
          \ 'on_exit': function('s:JobExit'),
          \ 'stdout_buffered': v:true,
          \ 'stderr_buffered': v:true,
          \ 'tempfile': a:request.file,
          \})
    " else
    "   call extend(l:opts, {
    "         \ 'on_exit': function('s:JobExit'),
    "         \ 'tempfile': a:request.file,
    "         \})
    " endif
  endif
  return l:opts
endfunction

function! s:SaveCurrentBufferPid(request)
  let l:pid = get(b:, 'terminal_job_pid', 0)
  call writefile([l:pid], a:request.file . '.pid')
  let a:request.pid = l:pid " This is used by Start! (see g:DISPATCH_STARTS)
endfunction

function! dispatch#neovim#handle(request) abort
  let l:action = a:request.action
  let l:cmd = a:request.expanded
  let l:bg = a:request.background
  let l:opts = s:CommandOptions(a:request)
  if s:UsesTerminal(a:request)
    if s:NeedsOutput(a:request)
      execute 'botright split | enew | resize 10'
      let l:opts.buf_id = bufnr('%')
      call termopen(l:cmd, l:opts)
      call s:SaveCurrentBufferPid(a:request)
      execute 'wincmd p'
    else
      execute 'tabnew'
      call termopen(l:cmd, l:opts)
      call s:SaveCurrentBufferPid(a:request)
      if l:bg
        execute 'tabprev'
      else
        execute 'startinsert'
      endif
    endif
  else
    let l:job_id = jobstart(l:cmd, l:opts)

    " Create empty file in case there is no output
    call writefile([], a:request.file)

    " There is currently no way to get the pid in neovim when using
    " jobstart. See: https://github.com/neovim/neovim/issues/557
    " Use job id as pid for now.
    call writefile([l:job_id], a:request.file.'.pid')
  endif
  return 1
endfunction

function! s:FindBufferByPID(pid) abort
  let l:bufcount = bufnr('$')
  for l:b in range(1, l:bufcount)
    if buflisted(l:b)
      if a:pid == getbufvar(l:b, 'terminal_job_pid', -1) + 0
        return l:b
      endif
    endif
  endfor
  return 0
endfunction

function! dispatch#neovim#activate(pid) abort
  let l:buf = s:FindBufferByPID(a:pid)
  if l:buf > 0
    for l:t in range(1, tabpagenr('$'))
      if index(tabpagebuflist(l:t), l:buf) != -1
        " When we find the buffer, switch to the right tab and window
        execute 'normal! '.l:t.'gt'
        execute bufwinnr(l:buf).'wincmd w'
        return 1
      endif
    endfor
  else
    " Program was not found among the buffers so nothing to activate
    return 0
  endif
endfunction


function! s:RemoveANSI(lines)
  return map(a:lines, 'substitute(v:val, ''\e[\[(][0-9;]*[a-zA-Z]'', "", "g")')
endfunction

function! s:BufferOutput(job_id, data, event) dict abort
  let l:lines = a:data
  let l:lines = filter(l:lines, '!empty(v:val)')
  let l:lines = s:RemoveANSI(l:lines)
  let l:lines = map(l:lines, 'substitute(v:val, "\r", "", "g")')
  call writefile(l:lines, self.tempfile, 'a')
endfunction

function! s:JobExit(job_id, data, event) dict abort
  " if s:UsesTerminal(self.request) && s:NeedsOutput(self.request)
  "   call writefile(getbufline(self.buf_id, 1, '$'), self.tempfile)
  " endif

  " Clean up terminal window if visible
  if !self.background
    let l:term_win = bufwinnr(self.buf_id)
    if l:term_win != -1
      let l:cur_win = winnr()
      execute l:term_win . ' wincmd w'
      call feedkeys("\<C-\>\<C-n>", 'n')
      execute l:cur_win . ' wincmd w'
      execute 'silent bd! ' . self.buf_id
    endif
  endif
  call writefile([a:data], self.tempfile . '.complete')
  call dispatch#complete(self.tempfile)
endfunction
