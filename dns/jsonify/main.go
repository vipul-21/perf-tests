/*
Copyright 2018 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io/ioutil"
	"os"
	"path/filepath"
	"time"

	"github.com/golang/glog"
	"gopkg.in/yaml.v2"
	"k8s.io/kubernetes/test/e2e/perftype"
)

const (
	// secToMsec is a second to millisecond ratio.
	secToMsec = float64((time.Second) / time.Millisecond)
)

// BenchmarkResult is a dns benchmark results structure.
type BenchmarkResult struct {
	Code   int             `yaml:"code"`
	Data   BenchmarkData   `yaml:"data"`
	Params BenchmarkParams `yaml:"params"`
}

// BenchmarkData represents dns benchmark data.
type BenchmarkData struct {
	Latency50Percentile float64 `yaml:"latency_50_percentile"`
	Latency95Percentile float64 `yaml:"latency_95_percentile"`
	Latency99Percentile float64 `yaml:"latency_99_percentile"`
	AvgLatency          float64 `yaml:"avg_latency"`
	MaxLatency          float64 `yaml:"max_latency"`
	MinLatency          float64 `yaml:"min_latency"`
	QPS                 float64 `yaml:"qps"`
	QueriesCompleted    float64 `yaml:"queries_completed"`
	QueriesLost         float64 `yaml:"queries_lost"`
	QueriesSent         float64 `yaml:"queries_sent"`
}

// BenchmarkParams represents dns benchmark params.
type BenchmarkParams struct {
	RunLengthSeconds float64  `yaml:"run_length_seconds"`
	QueryFile        string   `yaml:"query_file"`
	KubednsCPU       *float64 `yaml:"kubedns_cpu"`
	DnsmasqCPU       *float64 `yaml:"dnsmasq_cpu"`
	DnsmasqCache     *float64 `yaml:"dnsmasq_cache"`
	MaxQPS           *float64 `yaml:"max_qps"`
	PodName          string   `yaml:"pod_name"`
}

func main() {
	defer glog.Flush()
	err := run()
	if err != nil {
		panic(err)
	}
}

func run() error {
	var benchmarkDirPath, jsonDirPath, benchmarkName string
	flag.CommandLine = flag.NewFlagSet(os.Args[0], flag.ExitOnError)
	flag.StringVar(&benchmarkDirPath, "benchmarkDirPath", ".", "benchmark results directory path")
	flag.StringVar(&jsonDirPath, "jsonDirPath", ".", "json results directory path")
	flag.StringVar(&benchmarkName, "benchmarkName", ".", "benchmark name")

	if err := flag.CommandLine.Parse(os.Args[1:]); err != nil {
		return fmt.Errorf("flag parse failed: %v", err)
	}

	glog.Infof("benchmarkDirPath: %v\n", benchmarkDirPath)
	glog.Infof("jsonDirPath: %v\n", jsonDirPath)
	glog.Infof("benchmarkName: %v\n", benchmarkName)

	latency := perftype.PerfData{Version: "v1"}
	latencyPerc := perftype.PerfData{Version: "v1"}
	queries := perftype.PerfData{Version: "v1"}
	qps := perftype.PerfData{Version: "v1"}

	fileList, err := getFileList(benchmarkDirPath)
	if err != nil {
		return fmt.Errorf("listing files error: %v", err)
	}

	// Initialize aggregated data structures
	var (
		totalLatencyAvg, totalLatencyMin, totalLatencyMax         float64
		totalLatency50, totalLatency95, totalLatency99            float64
		totalQueriesSent, totalQueriesCompleted, totalQueriesLost float64
		totalQPS                                                  float64
		fileCount                                                 = 0
		labels                                                    map[string]string
	)

	for _, file := range fileList {
		glog.Infof("processing %s\n", file)
		result, err := readBenchmarkResult(filepath.Join(benchmarkDirPath, file))
		if err != nil {
			return err
		}

		if fileCount == 0 {
			labels = createLabels(&result.Params) // Use labels from first file
		}

		// Aggregate data directly instead of creating multiple data items
		totalLatencyAvg += result.Data.AvgLatency * secToMsec
		totalLatencyMin += result.Data.MinLatency * secToMsec
		totalLatencyMax += result.Data.MaxLatency * secToMsec

		totalLatency50 += result.Data.Latency50Percentile
		totalLatency95 += result.Data.Latency95Percentile
		totalLatency99 += result.Data.Latency99Percentile

		totalQueriesSent += result.Data.QueriesSent
		totalQueriesCompleted += result.Data.QueriesCompleted
		totalQueriesLost += result.Data.QueriesLost

		totalQPS += result.Data.QPS

		fileCount++
	}

	// Create single data points for each metric type
	if fileCount > 0 {
		count := float64(fileCount)

		latency.DataItems = []perftype.DataItem{{
			Unit:   "ms",
			Labels: labels,
			Data: map[string]float64{
				"avg_latency": totalLatencyAvg / count,
				"min_latency": totalLatencyMin / count,
				"max_latency": totalLatencyMax / count,
			},
		}}

		latencyPerc.DataItems = []perftype.DataItem{{
			Unit:   "ms",
			Labels: labels,
			Data: map[string]float64{
				"perc50": totalLatency50 / count,
				"perc90": totalLatency95 / count,
				"perc99": totalLatency99 / count,
			},
		}}

		queries.DataItems = []perftype.DataItem{{
			Unit:   "",
			Labels: labels,
			Data: map[string]float64{
				"queries_sent":      totalQueriesSent,
				"queries_completed": totalQueriesCompleted,
				"queries_lost":      totalQueriesLost,
			},
		}}

		qps.DataItems = []perftype.DataItem{{
			Unit:   "1/s",
			Labels: labels,
			Data: map[string]float64{
				"qps": totalQPS / count,
			},
		}}
	}

	// Always use "dns" as the middle part for consistent naming
	timeString := time.Now().Format("2006-01-02_15-04-05")

	// Clean up any existing JSON files in the target directory to avoid duplicates
	existingFiles, _ := filepath.Glob(filepath.Join(jsonDirPath, "*.json"))
	for _, file := range existingFiles {
		if filepath.Base(file) != "test_metadata.json" && filepath.Base(file) != "build_info.json" {
			os.Remove(file)
		}
	}

	if err = saveMetric(&latency, filepath.Join(jsonDirPath, "Latency_dns_"+timeString+".json")); err != nil {
		return err
	}
	if err = saveMetric(&latencyPerc, filepath.Join(jsonDirPath, "LatencyPerc_dns_"+timeString+".json")); err != nil {
		return err
	}
	if err = saveMetric(&queries, filepath.Join(jsonDirPath, "Queries_dns_"+timeString+".json")); err != nil {
		return err
	}
	if err = saveMetric(&qps, filepath.Join(jsonDirPath, "Qps_dns_"+timeString+".json")); err != nil {
		return err
	}

	return nil
}

// getFileList returns a list of all files with extension .out.
func getFileList(dir string) ([]string, error) {
	var fileNames []string
	files, err := ioutil.ReadDir(dir)
	if err != nil {
		return fileNames, err
	}

	for _, file := range files {
		if !file.IsDir() && filepath.Ext(file.Name()) == ".out" {
			fileNames = append(fileNames, file.Name())
		}
	}
	return fileNames, nil
}

func readBenchmarkResult(path string) (*BenchmarkResult, error) {
	var result BenchmarkResult
	bin, err := ioutil.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading error: %v", err)
	}

	if err := yaml.Unmarshal(bin, &result); err != nil {
		return nil, fmt.Errorf("decoding failed: %v", err)
	}
	return &result, nil
}

func toString(v *float64) string {
	if v == nil {
		return ""
	}
	return fmt.Sprintf("%v", *v)
}

func createLabels(params *BenchmarkParams) map[string]string {
	labels := make(map[string]string)
	labels["run_length_seconds"] = fmt.Sprintf("%v", params.RunLengthSeconds)
	labels["query_file"] = params.QueryFile
	labels["kubedns_cpu"] = toString(params.KubednsCPU)
	labels["dnsmasq_cpu"] = toString(params.DnsmasqCPU)
	labels["dnsmasq_cache"] = toString(params.DnsmasqCache)
	labels["max_qps"] = toString(params.MaxQPS)
	return labels

}

func appendLatency(items []perftype.DataItem, labels map[string]string, result *BenchmarkResult) []perftype.DataItem {
	return append(items, perftype.DataItem{
		Unit:   "ms",
		Labels: labels,
		Data: map[string]float64{
			"max_latency": result.Data.MaxLatency * secToMsec,
			"avg_latency": result.Data.AvgLatency * secToMsec,
			"min_latency": result.Data.MinLatency * secToMsec,
		},
	})
}

func appendLatencyPerc(items []perftype.DataItem, labels map[string]string, result *BenchmarkResult) []perftype.DataItem {
	return append(items, perftype.DataItem{
		Unit:   "ms",
		Labels: labels,
		Data: map[string]float64{
			"perc50": result.Data.Latency50Percentile,
			"perc90": result.Data.Latency95Percentile,
			"perc99": result.Data.Latency99Percentile,
		},
	})
}

func appendQueries(items []perftype.DataItem, labels map[string]string, result *BenchmarkResult) []perftype.DataItem {
	return append(items, perftype.DataItem{
		Unit:   "",
		Labels: labels,
		Data: map[string]float64{
			"queries_completed": result.Data.QueriesCompleted,
			"queries_lost":      result.Data.QueriesLost,
			"queries_sent":      result.Data.QueriesSent,
		},
	})
}

func appendQPS(items []perftype.DataItem, labels map[string]string, result *BenchmarkResult) []perftype.DataItem {
	return append(items, perftype.DataItem{
		Unit:   "1/s",
		Labels: labels,
		Data: map[string]float64{
			"qps": result.Data.QPS,
		},
	})
}

func saveMetric(metric *perftype.PerfData, path string) error {
	output := &bytes.Buffer{}
	if err := json.NewEncoder(output).Encode(metric); err != nil {
		return err
	}
	formatted := &bytes.Buffer{}
	if err := json.Indent(formatted, output.Bytes(), "", "  "); err != nil {
		return err
	}
	return ioutil.WriteFile(path, formatted.Bytes(), 0664)
}
