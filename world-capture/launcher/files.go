package main

import (
	"crypto/rand"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

// tempFile 在 dir 里写一个只有本人能读的临时文件。
func tempFile(dir, content string) (string, bool) {
	f, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return "", false
	}
	name := f.Name()
	_, err = f.WriteString(content)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(name)
		return "", false
	}
	os.Chmod(name, 0o600)
	return name, true
}

// replaceFile：先写临时文件再改名（mv -f，capture.ps1 的 Write-Atomic）。不在同一个卷上改不了名时，像 mv 一样直接写过去。
// 不重试：两份脚本写这些状态文件都只试一次。
func replaceFile(path, content, tmpDir string) bool {
	tmp, ok := tempFile(tmpDir, content)
	if !ok {
		return false
	}
	defer os.Remove(tmp)
	err := os.Rename(tmp, path)
	if err != nil && crossDevice(err) {
		return os.WriteFile(path, []byte(content), 0o600) == nil
	}
	return err == nil
}

// createFile：目标还没有时才写（ln 临时文件 目标）；已有的不动。
func createFile(path, content, tmpDir string) bool {
	tmp, ok := tempFile(tmpDir, content)
	if !ok {
		return false
	}
	defer os.Remove(tmp)
	return linkNew(tmp, path)
}

// newUUID：小写的随机 UUID（uuidgen | tr A-F a-f）。
func newUUID() string {
	b := make([]byte, 16)
	rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// pluginRoot：插件目录。程序在 <插件>/bin/ 下。
func pluginRoot() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return filepath.Dir(filepath.Dir(exe))
}

func sortedNames(dir string) []string {
	var names []string
	for n := range listNames(dir) {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// child：正在跑的 CLI，收到 TERM 时一起结束。
var child *os.Process
