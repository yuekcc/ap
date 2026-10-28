package client

import "../platform"

// 前端 kit 的公共类型。错误只关心 message，因此直接复用 platform。
Error :: platform.Error
Project :: platform.Project

ok_error :: platform.ok_error
errorf :: platform.errorf
is_ok :: platform.is_ok

// 取消与进程树原语：前端只 import client，不直接碰 platform。
Cancel_Token :: platform.Cancel_Token
cancel_token_cancel :: platform.cancel_token_cancel
cancel_token_cancelled :: platform.cancel_token_cancelled

cleanup_jobs :: platform.cleanup_jobs
