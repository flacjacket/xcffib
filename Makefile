BLACK=black -t py27

XCBDIR?=$(shell pkg-config --variable=xcbincludedir xcb-proto)
ifneq ($(XCBDIR),$(shell pkg-config --variable=xcbincludedir xcb-proto))
	XCBVER=$(shell sed -e '1,/AC_INIT/d' $(XCBDIR)/../configure.ac | head -n 1 | tr -d ,[:blank:])
else
	XCBVER=$(shell pkg-config --modversion xcb-proto)
endif
CABAL=cabal --config-file=./cabal.config
GEN=$(CABAL) new-run exe:xcffibgen --

# you should have xcb-proto installed to run this
xcffib: module/*.py
	$(GEN) --input $(XCBDIR) --output ./xcffib
	cp ./module/*py ./xcffib/
	touch ./xcffib/py.typed
	sed -i "s/__xcb_proto_version__ = .*/__xcb_proto_version__ = \"${XCBVER}\"/" xcffib/__init__.py
	@if [ "$(TRAVIS)" = true ]; then python xcffib/ffi_build.py; else python xcffib/ffi_build.py > /dev/null 2>&1 || python3 xcffib/ffi_build.py; fi

.PHONY: xcffib-fmt
xcffib-fmt: xcffib
	$(BLACK) ./xcffib/*.py

dist-newstyle:
	$(CABAL) new-configure --enable-tests

.PHONY: gen
gen: dist-newstyle
	$(CABAL) new-build

.PHONY: clean
clean:
	-$(CABAL) new-clean
	-rm -rf xcffib
	-rm -rf module/*pyc module/__pycache__
	-rm -rf test/*pyc test/__pycache__
	-rm -rf build *egg* *deb .pybuild
	-rm -rf .pc cabal.project.local*

# A target for just running nosetests. Travis will run 'check', which does
# everything. (Additionally, travis uses separate environments where nosetests
# points to The Right Thing for each, so we don't need to do nosetests3.)
pycheck: xcffib
	nosetests -d
	nosetests3 -d

valgrind: xcffib
	valgrind --leak-check=full --show-leak-kinds=definite nosetests -d

newtests:
	$(GEN) --input ./test/generator/ --output ./test/generator/
	git diff test

# These are all split out so make -j3 check goes as fast as possible.
.PHONY: lint
lint:
	flake8 --config=./test/flake8.cfg ./module

.PHONY: htests
htests:
	$(CABAL) new-test

check: xcffib lint htests
	nosetests -d -v

deb:
	git buildpackage --git-upstream-tree=master
	lintian

deb-src:
	git buildpackage --git-upstream-tree=master -S

# make release ver=0.99.99
release: xcffib
ifeq (${ver},)
	@echo "no version (ver=) specified, not releasing."
else ifneq ($(wildcard ./xcffib.egg-info*),)
	@echo "xcffib.egg-info exists, not releasing."
else
	sed -i "s/version = .*/version = \"${ver}\"/" setup.py
	sed -i "s/__version__ = .*/__version__ = \"${ver}\"/" xcffib/__init__.py
	sed -r -i -e "s/(^version = \s*)[\"0-9\.]*/\1\"${ver}\"/" setup.py
	sed -r -i -e "s/(^version:\s*)[0-9\.]*/\1${ver}/" xcffib.cabal
	git commit -a -m "Release v${ver}"
	git tag v${ver}
	python3 setup.py sdist
	python3 setup.py sdist upload
	cabal new-sdist
	cabal upload --publish dist-newstyle/sdist/xcffib-${ver}.tar.gz
endif
