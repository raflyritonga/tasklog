package obs

import (
	"os"
	"strconv"

	"github.com/DataDog/dd-trace-go/v2/profiler"
)

func StartProfiler(service, version, deployEnv string) (stop func(), enabled bool, err error) {
	on, _ := strconv.ParseBool(os.Getenv("DD_PROFILING_ENABLED"))
	if !on {
		return func() {}, false, nil
	}

	types := []profiler.ProfileType{profiler.CPUProfile, profiler.HeapProfile}
	if extra, _ := strconv.ParseBool(os.Getenv("DD_PROFILING_CONTENTION")); extra {
		types = append(types,
			profiler.GoroutineProfile,
			profiler.MutexProfile,
			profiler.BlockProfile,
		)
	}

	if err := profiler.Start(
		profiler.WithService(service),
		profiler.WithEnv(deployEnv),
		profiler.WithVersion(version),
		profiler.WithProfileTypes(types...),
	); err != nil {
		return func() {}, false, err
	}
	return profiler.Stop, true, nil
}
