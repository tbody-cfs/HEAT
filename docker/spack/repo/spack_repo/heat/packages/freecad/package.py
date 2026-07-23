# HEAT overlay of the spack builtin freecad (spack 1.2.2).
#
# The only change vs builtin is the added `depends_on("yaml-cpp", when="@1.0:")`.
# FreeCAD 1.0's cMake/FreeCAD_Helpers/SetupLibYaml.cmake does `find_package(yaml-cpp ...)`
# (CONFIG mode), but the builtin package — which also supports 0.20.2, predating that
# requirement — never declares yaml-cpp. So yaml-cpp is not in freecad's dependency closure
# and not on its CMAKE_PREFIX_PATH, and the build fails at configure with:
#   CMake Error at cMake/FreeCAD_Helpers/SetupLibYaml.cmake:3 (find_package):
#     Could not find a package configuration file provided by "yaml-cpp"
# (yaml-cpp@0.8.0 happens to be in the env already, pulled by adios2/mgard, but that's a
# sibling subtree so freecad's build can't see it.) Declaring the dep puts yaml-cpp on
# freecad's prefix path so find_package resolves. Guarded @1.0: so 0.20.2 is unaffected.
# See SPACK_MIGRATION_PROGRESS.md.

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
