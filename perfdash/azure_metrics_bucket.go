/*
Copyright 2024 The Kubernetes Authors.

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
	"context"
	"errors"
	"io"
	"strconv"
	"strings"

	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	containerblob "github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/container"
	"k8s.io/klog"
)

// AzureMetricsBucket that creates an Azure Blob Storage client to fetch data.
type AzureMetricsBucket struct {
	client      *containerblob.Client
	container   string
	logPath     string
	accountName string
}

// NewAzureMetricsBucket creates a new AzureMetricsBucket.
func NewAzureMetricsBucket(accountName, container, pathPrefix, connectionString string, useDefaultCredential bool, clientID, clientSecret, tenantID string) (MetricsBucket, error) {
	var client *containerblob.Client
	var err error

	klog.Infof("Creating NewAzureMetricsBucket")
	// if connectionString != "" {
	// 	// Use connection string if provided
	// 	klog.Infof("Using Azure connection string authentication")
	// 	client, err = azblob.NewClientFromConnectionString(connectionString, nil)
	// } else if clientID != "" && clientSecret != "" && tenantID != "" {
	// 	// Use Microsoft Entra ID (Azure AD) Service Principal credentials
	// 	klog.Infof("Using Microsoft Entra ID service principal authentication")
	// 	credential, err := azidentity.NewClientSecretCredential(tenantID, clientID, clientSecret, nil)
	// 	if err != nil {
	// 		return nil, errors.New("failed to create Microsoft Entra ID credential: " + err.Error())
	// 	}
	// 	serviceURL := "https://" + accountName + ".blob.core.windows.net/"
	// 	client, err = azblob.NewClient(serviceURL, credential, nil)
	// } else if useDefaultCredential {
	// 	// Use Azure Default Credential (managed identity, Azure CLI, etc.)
	// 	klog.Infof("Using Azure Default Credential authentication")
	// 	credential, err := azidentity.NewDefaultAzureCredential(nil)
	// 	klog.Infof("Using Azure Default Credentia8l for account: %v", credential)
	// 	if err != nil {
	// 		klog.Info("Failed to create Azure default credential: ", err)
	// 		return nil, errors.New("failed to create Azure default credential: " + err.Error())
	// 	}
	// 	klog.Infof("Using Azure Default Credential for account: %v", credential)
	// 	//serviceURL := "https://" + accountName + ".blob.core.windows.net/"
	// 	//client, err = azblob.NewClient(serviceURL, credential, nil)
	// 	containerURL := "https://" + accountName + ".blob.core.windows.net/" + container
	// 	client, err := containerblob.NewClient(containerURL, credential, nil)
	// } else {
	// 	// Use anonymous access
	// 	klog.Infof("Using anonymous access to Azure Blob Storage")
	// 	serviceURL := "https://" + accountName + ".blob.core.windows.net/"
	// 	client, err = azblob.NewClientWithNoCredential(serviceURL, nil)
	// }

	// Use Azure Default Credential (managed identity, Azure CLI, etc.)

	klog.Infof("Using Azure Default Credential authentication")

	credential, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		klog.Info("Failed to create Azure default credential: ", err)
		return nil, errors.New("failed to create Azure default credential: " + err.Error())
	}
	klog.Infof("Using Azure Default Credential for account: %v", credential)
	containerURL := "https://" + accountName + ".blob.core.windows.net/" + container
	client, err = containerblob.NewClient(containerURL, credential, nil)

	if err != nil {
		return nil, errors.New("failed to create Azure blob client: " + err.Error())
	}

	return &AzureMetricsBucket{
		client:      client,
		container:   container,
		logPath:     pathPrefix,
		accountName: accountName,
	}, nil
}

// GetBuildNumbers fetches the build numbers from an Azure Blob Storage container.
func (a *AzureMetricsBucket) GetBuildNumbers(job string) ([]int, error) {
	klog.Info("Fetching build numbers from Azure Blob Storage")
	var builds []int
	buildMap := make(map[int]bool)           // Use map to avoid duplicates
	jobPrefix := a.logPath + "/" + job + "/" //joinStringsAndInts(a.logPath, job) + "/"
	klog.Infof("Azure: Listing blobs with prefix: %s", jobPrefix)

	ctx := context.Background()
	pager := a.client.NewListBlobsFlatPager(&containerblob.ListBlobsFlatOptions{
		Prefix: &jobPrefix,
	})
	klog.Infof("Azure: Starting to list blobs")

	for pager.More() {
		resp, err := pager.NextPage(ctx)
		if err != nil {
			klog.Errorf("failed to list blobs: %v", err)
			return nil, errors.New("failed to list blobs: " + err.Error())
		}

		for _, blob := range resp.Segment.BlobItems {
			if blob.Name == nil {
				continue
			}

			// Extract build number from blob path
			// Expected format: <logPath>/<job>/<buildNumber>/...
			relativePath := strings.TrimPrefix(*blob.Name, jobPrefix)
			parts := strings.Split(relativePath, "/")
			if len(parts) > 0 && parts[0] != "" {
				buildNo, err := strconv.Atoi(parts[0])
				if err != nil {
					continue // Skip non-numeric build directories
				}
				klog.Info("Found build number:", buildNo)
				buildMap[buildNo] = true
			}
		}
	}

	// Convert map keys to slice
	for buildNo := range buildMap {
		builds = append(builds, buildNo)
	}

	return builds, nil
}

// ListFilesInBuild fetches the files in the build from Azure Blob Storage.
func (a *AzureMetricsBucket) ListFilesInBuild(job string, buildNumber int, prefix string) ([]string, error) {
	var files []string
	jobPrefix := joinStringsAndInts(a.logPath, job, buildNumber, prefix)

	ctx := context.Background()
	pager := a.client.NewListBlobsFlatPager(&containerblob.ListBlobsFlatOptions{
		Prefix: &jobPrefix,
	})

	for pager.More() {
		resp, err := pager.NextPage(ctx)
		if err != nil {
			klog.Errorf("failed to list blobs: %v", err)
			return nil, errors.New("failed to list blobs: " + err.Error())
		}

		for _, blob := range resp.Segment.BlobItems {
			if blob.Name != nil {
				klog.Infof("Found blob in build: %s", *blob.Name)
				files = append(files, *blob.Name)
			}
		}
	}

	return files, nil
}

func (a *AzureMetricsBucket) GetFilePrefix(job string, buildNumber int, prefix string) string {
	return joinStringsAndInts(a.logPath, job, buildNumber, prefix)
}

// ReadFile reads the file contents from the Azure Blob Storage container.
func (a *AzureMetricsBucket) ReadFile(job string, buildNumber int, path string) ([]byte, error) {
	blobPath := joinStringsAndInts(a.logPath, job, buildNumber, path)

	ctx := context.Background()

	// Remove the container prefix from blobPath since we're using container client
	// The blobPath should be relative to the container, not include the container name
	relativeBlobPath := blobPath
	if strings.HasPrefix(blobPath, a.container+"/") {
		relativeBlobPath = strings.TrimPrefix(blobPath, a.container+"/")
	}

	// Get a blob client for the specific blob
	blobClient := a.client.NewBlobClient(relativeBlobPath)

	resp, err := blobClient.DownloadStream(ctx, nil)
	if err != nil {
		klog.Errorf("failed to download blob %s: %v", relativeBlobPath, err)
		return nil, errors.New("failed to download blob " + relativeBlobPath + ": " + err.Error())
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		klog.Errorf("failed to read blob data: %v", err)
		return nil, errors.New("failed to read blob data: " + err.Error())
	}
	return data, nil
}
