# HEAT overlay of the spack builtin freecad (spack 1.2.2).
#
# Changes vs builtin, all guarded @1.0: (0.20.2 is untouched):
#   1. depends_on("yaml-cpp"): 1.0's cMake/FreeCAD_Helpers/SetupLibYaml.cmake does
#      find_package(yaml-cpp) (CONFIG mode), but the builtin package — which also supports
#      0.20.2, predating that requirement — never declares the dep, so yaml-cpp is absent from
#      freecad's CMAKE_PREFIX_PATH and configure fails:
#        CMake Error at cMake/FreeCAD_Helpers/SetupLibYaml.cmake:3 (find_package):
#          Could not find a package configuration file provided by "yaml-cpp"
#      Declaring the dep puts yaml-cpp on freecad's prefix path so find_package resolves.
#   2. patch(): drop the header-only boost `system` component from SetupBoost.cmake — Boost
#      1.89 ships no compiled boost_system and no boost_system CMake config, so the REQUIRED
#      find fails. (See the comment at that filter_file.)
#   3. patch(): make SMESH's HDF5 pkg-config probe resolve spack's hdf5.pc, avoiding a
#      poisoned find_package(HDF5) fallback. (See the comment at that filter_file.)

from spack_repo.builtin.build_systems.cmake import CMakePackage

from spack.package import *


class Freecad(CMakePackage):
    """FreeCAD is an open-source parametric 3D modeler made primarily
    to design real-life objects of any size. Parametric modeling
    allows you to easily modify your design by going back into your
    model history to change its parameters."""

    homepage = "https://www.freecad.org/"
    url = "https://github.com/FreeCAD/FreeCAD/archive/refs/tags/0.20.2.tar.gz"
    git = "https://github.com/FreeCAD/FreeCAD"

    maintainers("aweits")

    license("LGPL-2.0-or-later")

    version("1.0.2", commit="256fc7eff3379911ab5daf88e10182c509aa8052", submodules=True)
    version("1.0.1", commit="878f0b8c9c72c6f215833a99f2762bc3a3cf2abd", submodules=True)
    version("0.20.2", sha256="46922f3a477e742e1a89cd5346692d63aebb2b67af887b3e463e094a4ae055da")

    depends_on("c", type="build")  # generated
    depends_on("cxx", type="build")  # generated
    depends_on("fortran", type="build")  # generated

    depends_on("opencascade")
    depends_on("xerces-c")
    depends_on("vtk")
    depends_on("med")
    depends_on(
        "boost+python+filesystem+date_time+graph+iostreams+program_options+regex+serialization+system+thread"  # noqa: E501
    )
    depends_on("qt@5:")
    depends_on("swig", type="build")
    depends_on("netgen")
    depends_on("pcl")
    depends_on("coin3d")
    depends_on("python")
    depends_on("gmsh+opencascade")
    depends_on("py-pyside2@1.2.4:", type=("build", "run"))
    depends_on("py-matplotlib@3.0.2:", type=("build", "run"))
    depends_on("py-six@1.12.0:", type=("build", "run"))
    depends_on("py-markdown@3.2.2:", type=("build", "run"))
    depends_on("py-pivy", type=("build", "run"))
    depends_on("py-pybind11", type="build")
    depends_on("yaml-cpp", when="@1.0:")  # HEAT overlay: 1.0's SetupLibYaml.cmake find_package(yaml-cpp)

    def patch(self):
        filter_file(
            "# include <Standard_TooManyUsers.hxx>", "", "src/Mod/Part/App/OCCError.h", string=True
        )
        filter_file('putenv("PYTHONPATH=");', "", "src/Main/MainGui.cpp", string=True)
        filter_file('_putenv("PYTHONPATH=");', "", "src/Main/MainGui.cpp", string=True)

        if self.spec.satisfies("@1.0:"):
            # HEAT overlay: Boost 1.89 made Boost.System header-only — there is no compiled
            # boost_system library and no `boost_system` CMake component config. FreeCAD 1.0's
            # SetupBoost.cmake still lists `system` in find_package(Boost COMPONENTS ... REQUIRED),
            # so configure dies: "Could not find a package configuration file provided by
            # boost_system". Drop the header-only `system` component (its symbols come in via the
            # Boost headers / Boost::filesystem, which is still a compiled component here).
            filter_file(
                "BOOST_COMPONENTS filesystem program_options regex system thread date_time",
                "BOOST_COMPONENTS filesystem program_options regex thread date_time",
                "cMake/FreeCAD_Helpers/SetupBoost.cmake",
                string=True,
            )

            # HEAT overlay: SMESH's HDF5 discovery collides with spack's hdf5. Our med is MPI, so
            # SetupSalomeSMESH.cmake sets HDF5_VARIANT=hdf5-openmpi and does
            # `pkg_search_module(HDF5 ${HDF5_VARIANT})` (line 98). Spack ships hdf5.pc / hdf5_hl.pc,
            # never the Debian-named hdf5-openmpi.pc, so that probe FAILS — which both leaves junk in
            # the shared HDF5_* variable namespace and forces the else path `find_package(HDF5 REQUIRED)`
            # (line 100). That find then aborts configure with
            #   Could NOT find HDF5 (missing: HDF5_HL_LIBRARIES) (found version "1.14.6")
            # even though libhdf5_hl.so is present (pure detection breakage — NOT a missing +hl; hdf5
            # is already +hl). Fix: add plain `hdf5` to the pkg_search module list. spack puts hdf5.pc
            # on PKG_CONFIG_PATH in freecad's build env, so the probe succeeds, HDF5_FOUND goes true,
            # and SMESH takes its clean pkg-config else-branch (add_compile_options / link_libraries /
            # find_file(hdf5.h)), never reaching the poisoned find_package. Root cause reproduced
            # and the fix verified with a standalone find_package(HDF5 ... COMPONENTS C HL) CMake
            # repro against the spack hdf5 prefix.
            #
            # NB: hdf5 +hl (see spack.yaml) is REQUIRED, not incidental — once this probe succeeds,
            # libSMESH.so links libhdf5_hl.so directly (HL is populated at detection). Dropping +hl
            # in a future slimming pass would break the SMESH link. Keep +hl.
            filter_file(
                "pkg_search_module(HDF5 ${HDF5_VARIANT})",
                "pkg_search_module(HDF5 ${HDF5_VARIANT} hdf5)",
                "cMake/FreeCAD_Helpers/SetupSalomeSMESH.cmake",
                string=True,
            )

            # PCL >= 1.12 removed pcl/point_traits.h (its contents moved to pcl/type_traits.h
            # in 1.11). FreeCAD 1.0's SurfaceTriangulation.cpp still includes the old header, so
            # the build fails at compile with "fatal error: pcl/point_traits.h: No such file or
            # directory". Swap it for the replacement — the same one-line fix FreeCAD applied
            # upstream after 1.0. This is the only file in the tree with the old include.
            filter_file(
                "#include <pcl/point_traits.h>",
                "#include <pcl/type_traits.h>",
                "src/Mod/ReverseEngineering/App/SurfaceTriangulation.cpp",
                string=True,
            )

    def cmake_args(self):
        args = []
        # requires qt5 + webkit, which requires python2
        args.append("-DBUILD_WEB=OFF")
        args.append("-DFREECAD_USE_PYBIND11:BOOL=ON")
        args.append("-DFREECAD_USE_PCL:BOOL=ON")
        # TODO:
        #       args.append("-DBUILD_FEM_NETGEN:BOOL=ON")
        #       args.append("-DNETGEN_INCLUDEDIR={}".format(self.spec["netgen"].prefix.include))
        return args
