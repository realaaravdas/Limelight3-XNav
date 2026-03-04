#[cfg(ocvrs_has_module_calib3d)]
include!(concat!(env!("OUT_DIR"), "/opencv/calib3d.rs"));
#[cfg(ocvrs_has_module_core)]
include!(concat!(env!("OUT_DIR"), "/opencv/core.rs"));
#[cfg(ocvrs_has_module_features2d)]
include!(concat!(env!("OUT_DIR"), "/opencv/features2d.rs"));
#[cfg(ocvrs_has_module_flann)]
include!(concat!(env!("OUT_DIR"), "/opencv/flann.rs"));
#[cfg(ocvrs_has_module_imgcodecs)]
include!(concat!(env!("OUT_DIR"), "/opencv/imgcodecs.rs"));
#[cfg(ocvrs_has_module_imgproc)]
include!(concat!(env!("OUT_DIR"), "/opencv/imgproc.rs"));
#[cfg(ocvrs_has_module_objdetect)]
include!(concat!(env!("OUT_DIR"), "/opencv/objdetect.rs"));
#[cfg(ocvrs_has_module_videoio)]
include!(concat!(env!("OUT_DIR"), "/opencv/videoio.rs"));
pub mod types {
	include!(concat!(env!("OUT_DIR"), "/opencv/types.rs"));
}
#[doc(hidden)]
pub mod sys {
	include!(concat!(env!("OUT_DIR"), "/opencv/sys.rs"));
}
pub mod hub_prelude {
	#[cfg(ocvrs_has_module_calib3d)]
	pub use super::calib3d::prelude::*;
	#[cfg(ocvrs_has_module_core)]
	pub use super::core::prelude::*;
	#[cfg(ocvrs_has_module_features2d)]
	pub use super::features2d::prelude::*;
	#[cfg(ocvrs_has_module_flann)]
	pub use super::flann::prelude::*;
	#[cfg(ocvrs_has_module_imgcodecs)]
	pub use super::imgcodecs::prelude::*;
	#[cfg(ocvrs_has_module_imgproc)]
	pub use super::imgproc::prelude::*;
	#[cfg(ocvrs_has_module_objdetect)]
	pub use super::objdetect::prelude::*;
	#[cfg(ocvrs_has_module_videoio)]
	pub use super::videoio::prelude::*;
}

mod ffi_exports {
	use crate::mod_prelude_sys::*;
	#[no_mangle] unsafe extern "C" fn ocvrs_create_string_0_93_7(s: *const c_char) -> *mut String { crate::templ::ocvrs_create_string(s) }
	#[no_mangle] unsafe extern "C" fn ocvrs_create_byte_string_0_93_7(v: *const u8, len: size_t) -> *mut Vec<u8> { crate::templ::ocvrs_create_byte_string(v, len) }
}
