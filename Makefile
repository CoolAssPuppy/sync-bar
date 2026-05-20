.PHONY: bootstrap build run test clean release lint format

bootstrap:
	./scripts/bootstrap.sh

build:
	./scripts/build.sh

release:
	./scripts/build.sh release

run:
	./scripts/run.sh

test:
	./scripts/test.sh

lint:
	./scripts/lint.sh

clean:
	rm -rf build SyncBar.xcodeproj
	rm -rf "$(HOME)/Library/Developer/Xcode/DerivedData/SyncBar-"*
