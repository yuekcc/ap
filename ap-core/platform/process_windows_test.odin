#+build windows
package platform

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// 并发登记同一个 job：去重检查与插入必须原子，否则作业表里会出现重复项，
// 关停时会对同一个句柄 CloseHandle/Terminate 两次。
JOB_TEST_WORKERS :: 6
JOB_TEST_REGISTRATIONS :: 100

Job_Test_Barrier :: struct {
	ready:  i32,
	go:     i32,
	job:    Job_Handle,
}

job_test_worker :: proc(user: rawptr) {
	state := (^Job_Test_Barrier)(user)
	sync.atomic_add(&state.ready, 1)
	for sync.atomic_load(&state.go) == 0 {
		thread.yield()
	}
	for _ in 0 ..< JOB_TEST_REGISTRATIONS {
		register_job(state.job)
	}
}

job_table_length :: proc() -> int {
	sync.mutex_lock(&running_jobs_mu)
	defer sync.mutex_unlock(&running_jobs_mu)
	return len(running_jobs)
}

job_table_count :: proc(job: Job_Handle) -> int {
	sync.mutex_lock(&running_jobs_mu)
	defer sync.mutex_unlock(&running_jobs_mu)
	count := 0
	for existing in running_jobs {
		if existing == job {
			count += 1
		}
	}
	return count
}

@(test)
test_register_job_is_safe_under_concurrency :: proc(t: ^testing.T) {
	// 先清空全局表，避免其它测试的残留影响断言。
	sync.mutex_lock(&running_jobs_mu)
	clear(&running_jobs)
	sync.mutex_unlock(&running_jobs_mu)

	state := Job_Test_Barrier{job = Job_Handle(uintptr(CreateJobObjectW(nil, nil)))}
	testing.expect(t, state.job != 0, "cannot create test job object")

	handles: [JOB_TEST_WORKERS]^thread.Thread
	for i in 0 ..< JOB_TEST_WORKERS {
		handles[i] = thread.create_and_start_with_data(
			rawptr(&state),
			job_test_worker,
			name = "job-register",
		)
		testing.expect(t, handles[i] != nil, "cannot start worker")
	}
	start := time.tick_now()
	for sync.atomic_load(&state.ready) < JOB_TEST_WORKERS &&
	    time.tick_since(start) < 5 * time.Second {
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, sync.atomic_load(&state.ready), i32(JOB_TEST_WORKERS))
	sync.atomic_store(&state.go, 1)
	for i in 0 ..< JOB_TEST_WORKERS {
		thread.join(handles[i])
		thread.destroy(handles[i])
	}

	testing.expect_value(t, job_table_count(state.job), 1)
	release_job(state.job)
	testing.expect_value(t, job_table_length(), 0)
}
