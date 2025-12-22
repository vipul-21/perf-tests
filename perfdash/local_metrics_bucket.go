/*
Copyright 2025 The Kubernetes Authors.

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
	"fmt"
	"io/ioutil"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"k8s.io/klog"
)

// LocalMetricsBucket reads metrics from local filesystem
type LocalMetricsBucket struct {
	basePath string
	logPath  string
}

// NewLocalMetricsBucket creates a new LocalMetricsBucket
// basePath is the root directory containing the logs
// logPath is the subdirectory within basePath (e.g., "logs")
func NewLocalMetricsBucket(basePath, logPath string) (MetricsBucket, error) {
	fullPath := filepath.Join(basePath, logPath)

	// Verify the path exists
	if _, err := os.Stat(fullPath); os.IsNotExist(err) {
		return nil, fmt.Errorf("local metrics path does not exist: %s", fullPath)
	}

	klog.Infof("Using local metrics bucket at: %s", fullPath)
	return &LocalMetricsBucket{
		basePath: basePath,
		logPath:  logPath,
	}, nil
}

// GetBuildNumbers fetches the build numbers from local filesystem
func (b *LocalMetricsBucket) GetBuildNumbers(job string) ([]int, error) {
	var builds []int
	jobPath := filepath.Join(b.basePath, b.logPath, job)

	klog.Infof("Reading builds from: %s", jobPath)

	// Check if job directory exists
	if _, err := os.Stat(jobPath); os.IsNotExist(err) {
		klog.Warningf("Job directory does not exist: %s", jobPath)
		return builds, nil
	}

	// Read directory entries
	entries, err := ioutil.ReadDir(jobPath)
	if err != nil {
		return nil, fmt.Errorf("error reading job directory %s: %v", jobPath, err)
	}

	// Parse build numbers from directory names
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		buildNo, err := strconv.Atoi(entry.Name())
		if err != nil {
			klog.Warningf("Skipping non-numeric directory: %s", entry.Name())
			continue
		}

		// Verify finished.json exists to ensure build is complete
		finishedFile := filepath.Join(jobPath, entry.Name(), "finished.json")
		if _, err := os.Stat(finishedFile); err == nil {
			builds = append(builds, buildNo)
			klog.Infof("Found build %d for job %s", buildNo, job)
		} else {
			klog.Warningf("Build %d missing finished.json, skipping", buildNo)
		}
	}

	return builds, nil
}

// ListFilesInBuild fetches the files in the build from local filesystem
func (b *LocalMetricsBucket) ListFilesInBuild(job string, buildNumber int, prefix string) ([]string, error) {
	var files []string
	buildPath := filepath.Join(b.basePath, b.logPath, job, strconv.Itoa(buildNumber))

	klog.Infof("ListFilesInBuild: %s with prefix '%s'", buildPath, prefix)

	// Walk through the build directory (including artifacts subdirectory)
	err := filepath.Walk(buildPath, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		if info.IsDir() {
			return nil
		}

		// Get relative path from buildPath
		relPath, err := filepath.Rel(buildPath, path)
		if err != nil {
			return err
		}

		// Check if file matches prefix
		// Note: prefix can be empty or a partial filename (not a path)
		filename := filepath.Base(relPath)
		if prefix == "" || prefix == "/" || strings.HasPrefix(filename, prefix) {
			files = append(files, relPath)
			klog.V(4).Infof("  Matched: %s (filename: %s, prefix: %s)", relPath, filename, prefix)
		} else {
			klog.V(5).Infof("  Skipped: %s (filename: %s, prefix: %s)", relPath, filename, prefix)
		}

		return nil
	})

	if err != nil {
		return nil, fmt.Errorf("error walking build directory %s: %v", buildPath, err)
	}

	klog.Infof("Found %d files matching prefix %s in build %d", len(files), prefix, buildNumber)
	return files, nil
}

// GetFilePrefix returns the file prefix for a given job, build, and prefix
// This should return a relative path from the build directory, not an absolute path
func (b *LocalMetricsBucket) GetFilePrefix(job string, buildNumber int, prefix string) string {
	// Just return the prefix as-is, since our ListFilesInBuild returns relative paths
	return prefix
}

// ReadFile reads a file from local filesystem
func (b *LocalMetricsBucket) ReadFile(job string, buildNumber int, path string) ([]byte, error) {
	fullPath := filepath.Join(b.basePath, b.logPath, job, strconv.Itoa(buildNumber), path)

	klog.V(4).Infof("Reading file: %s", fullPath)

	data, err := ioutil.ReadFile(fullPath)
	if err != nil {
		return nil, fmt.Errorf("error reading file %s: %v", fullPath, err)
	}

	return data, nil
}
