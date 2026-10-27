package main

import (
	"os"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/cli"
)

func main() {
	os.Exit(cli.New().Run(os.Args[1:]))
}
