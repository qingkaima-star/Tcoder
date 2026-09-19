import Foundation
@testable import TcoderMonitor

// WS-F 夹具树正文段：清单类（Go / Rust / Python / Ruby / CocoaPods / NuGet）。
// 逐行原样搬自 ManifestLabFixtureTests.swift 的 build(at:)，只加了同签名的函数外壳，
// 正文与多行字符串的缩进未动（WS-V 机械拆分）。
extension LabTree {
    static func writeManifestsGoAndRust(put: (String, String) throws -> Void,
                                  putLines: (String, [String]) throws -> Void) throws {

        // MARK: Go / Rust

        try put("go.mod", #"""
        module github.com/acme/orders-lab

        go 1.21

        toolchain go1.21.6

        require (
        	github.com/gin-gonic/gin v1.9.1
        	github.com/go-redis/redis/v8 v8.11.5
        	go.uber.org/zap v1.26.0
        )

        require (
        	github.com/golang/protobuf v1.5.3 // indirect
        	golang.org/x/sys v0.12.0 // indirect
        )

        replace github.com/acme/orders-lab/unused => ../unused

        require gopkg.in/yaml.v3 v3.0.1

        """#)

        try put("go.sum", #"""
        github.com/gin-gonic/gin v1.9.1 h1:QK/2gViFaWBk0Ny70d/uZfuvrPi7PX+6ZZtnMvBojw0=
        github.com/gin-gonic/gin v1.9.1/go.mod h1:hofw3Dfh8Rue3O196Nw/kdx3w9IdUhYv6Db1CG0hbew=

        """#)

        try putLines("service/main.go", [
            "package main",
            "",
            "import (",
            "\t\"fmt\"",
            "\t\"log\"",
            "",
            "\t\"github.com/acme/orders-lab/pkg/decode\"",
            ")",
            "",
            "// serve routes one order per line read from stdin.",
            "func main() {",
            "\treader := decode.New()",
            "\tfor reader.More() {",
            "\t\torder, err := reader.Next()",
            "\t\tif err != nil {",
            "\t\t\tlog.Fatalf(\"decode failed: %v\", err)",
            "\t\t}",
            "\t\t// TODO: 把这条决策路径接到真正的调度器上。",
            "\t\tfmt.Printf(\"lane %s state %s\\n\", order.Lane, order.CurrentState())",
            "\t}",
            "}",
            "",
        ])

        try putLines("pkg/decode/decoder.go", [
            "package decode",
            "",
            "// Order is the wire form used by the lab fixtures.",
            "type Order struct {",
            "\tLane string",
            "\tID   int",
            "}",
            "",
            "// CurrentState keeps the tiny state machine used by the fixture.",
            "func (order Order) CurrentState() string {",
            "\tif order.ID <= 0 {",
            "\t\treturn \"draft\"",
            "\t}",
            "\treturn \"new\"",
            "}",
            "",
            "// Reader walks the fixture rows.",
            "type Reader struct{}",
            "",
            "func New() *Reader { return &Reader{} }",
            "",
            "func (reader *Reader) More() bool { return false }",
            "",
            "func (reader *Reader) Next() (Order, error) { return Order{}, nil }",
            "",
        ])

        try put("Cargo.toml", #"""
        [package]
        name = "acme-orders-worker"
        version = "0.3.1"
        edition = "2021"

        [dependencies]
        serde = { version = "1.0.190", features = ["derive"] }
        tokio = { version = "1.37.0", features = ["macros", "rt-multi-thread"] }
        reqwest = { git = "https://github.com/acme/reqwest-fork", branch = "main" }
        anyhow = "1.0.79"

        [dev-dependencies]
        tempfile = "3.10.0"

        [build-dependencies]
        cc = "1.0.83"

        """#)

        try put("Cargo.lock", #"""
        version = 3

        [[package]]
        name = "acme-orders-worker"
        version = "0.3.1"

        """#)

        try putLines("rust-worker/src/main.rs", [
            "use anyhow::Result;",
            "",
            "fn lane_weight(lane: &str) -> u32 {",
            "    match lane {",
            "        \"domestic\" => 1,",
            "        \"cross_border\" => 4,",
            "        _ => 2,",
            "    }",
            "}",
            "",
            "fn main() -> Result<()> {",
            "    println!(\"worker up {}\", lane_weight(\"domestic\"));",
            "    Ok(())",
            "}",
            "",
        ])


    }

    static func writeManifestsPythonRubyAndDotNet(put: (String, String) throws -> Void,
                                  putLines: (String, [String]) throws -> Void) throws {

        // MARK: Python / Ruby / CocoaPods / NuGet

        try put("pyproject.toml", #"""
        [build-system]
        requires = ["setuptools>=68", "wheel"]
        build-backend = "setuptools.build_meta"

        [project]
        name = "acme-inventory"
        version = "0.9.4"
        requires-python = ">=3.11"
        dependencies = [
          "requests>=2.28.1,<3",
          "pydantic>=2.4",
          "rich",
        ]

        [project.optional-dependencies]
        cli = ["click>=8.1", "toml"]

        [dependency-groups]
        dev = ["pytest>=8.0", "ruff==0.1.9"]

        """#)

        try put("python-tool/requirements.txt", #"""
        # Pinned runtime requirements for the inventory worker.
        flask>=3.0.0
        pandas==2.1.4
        -r ../extras.txt
        uvicorn[standard]==0.27.0  # ASGI server

        """#)

        try putLines("python-tool/src/inventory.py", [
            "from dataclasses import dataclass",
            "",
            "",
            "@dataclass",
            "class StockLine:",
            "    sku: str",
            "    on_hand: int",
            "",
            "    def is_low(self, threshold: int = 4) -> bool:",
            "        # TODO: 阈值应当从库存策略表里读，而不是写死在这里。",
            "        return self.on_hand < threshold",
            "",
            "    def reorder_point(self) -> int:",
            "        # FIXME: 这里的提前期算法还没跟采购对齐。",
            "        return max(1, self.on_hand // 2)",
            "",
        ])

        try put("Gemfile", #"""
        source 'https://rubygems.org'

        gem 'rails', '~> 7.1.2'
        gem 'nokogiri', '>= 1.13.10'
        gem 'puma', '6.4.0'

        group :test do
          gem 'rspec', '~> 3.12.2'
        end

        group :development, :lint do
          gem 'rubocop', '~> 1.59.0', require: false
        end

        """#)

        try put("Gemfile.lock", #"""
        GEM
          remote: https://rubygems.org/
          specs:

        PLATFORMS
          arm64-darwin

        """#)

        try put("ios/Podfile", #"""
        platform :ios, '16.0'
        use_frameworks!

        pod 'Alamofire', '~> 5.8.1'
        pod 'SnapKit', '~> 5.6.0'

        target 'ACMEOrdersKitTests' do
          pod 'Nimble', '~> 13.0.0'
        end

        """#)

        try put("ios/Podfile.lock", #"""
        PODS:
          - Alamofire (5.8.1)

        """#)

        try put("dotnet/packages.config", #"""
        <?xml version="1.0" encoding="utf-8"?>
        <packages>
          <package id="Newtonsoft.Json" version="12.0.3" targetFramework="net472" />
          <package id="Serilog" version="3.1.1" targetFramework="net472" developmentDependency="true" />
        </packages>

        """#)

    }
}
