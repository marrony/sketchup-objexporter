require 'sketchup.rb'

# class Sketchup::Image
#     if not Sketchup::Image.method_defined?(:definition)
#       def definition()
#         if not self.valid?
#             puts("Image "+self.to_s+" is no longer valid.")
#             return false
#         end
#         self.model.definitions.each { |d| return d if d.image? && d.instances.include?(self)}
#         return nil
#       end
#     end
#
#     if not Sketchup::Image.method_defined?(:transformation)
#       def transformation()
#         if not self.valid?
#             puts("Image "+self.to_s+" is no longer valid.")
#             return false
#         end
#
#         origin = self.origin
#         axes = self.normal.axes
#         tr = Geom::Transformation.axes(ORIGIN, axes.at(0), axes.at(1), axes.at(2))
#         tr = tr*Geom::Transformation.rotation(ORIGIN, Z_AXIS, self.zrotation)
#         tr = (tr*Geom::Transformation.scaling(ORIGIN, self.width/self.pixelwidth, self.height/self.pixelheight, 1)).to_a
#         tr[12] = origin.x
#         tr[13] = origin.y
#         tr[14] = origin.z
#         return Geom::Transformation.new(tr)
#       end
#     end
#
#     if not Sketchup::Image.method_defined?(:transformation=)
#       def transformation=(tr)
#         if not self.valid?
#             puts("Image "+self.to_s+" is no longer valid.")
#             return false
#         end#if
#         if tr.class==Array
#           tr=Geom::Transformation.new(tr)
#         end#if
#         status=self.transform!(self.transformation.inverse * tr)
#         if status
#           return self
#         else
#           return nil
#         end#if
#       end
#     end#if
# end# Image class
#
# class Sketchup::Group
#     # Sometimes the group.entities.parent refer to the wrong definition.
#     # This checks for error and locates the correct parent definition.
#     if not Sketchup::Group.method_defined?(:definition)
#         def definition()
#           if self.entities.parent.instances.include?(self)
#             return self.entities.parent
#           else
#             Sketchup.active_model.definitions.each { |definition|
#                 return definition if definition.instances.include?(self)
#             }
#           end
#           return nil # Should not happen.
#         end
#     end#if
# end# group class

class OBJexporter

    def initialize()
        @model = Sketchup.active_model

        path = @model.path.tr("\\", "/")
        if path.empty?
            UI.messagebox("OBJExporter:\n\nSave the SKP before Exporting it as OBJ\n")
            return nil
        end

        @project_path = File.dirname(path)
        @title = self.fix_name(@model.title)
        @base_name = @title

        ### save dialog
        result = UI.savepanel("OBJExporter - File Name?", @project_path, @base_name + ".obj")

        return nil if not result or result == ""

        @sel = @model.selection

        if @sel and @sel[0]
            UI.beep
            if UI.messagebox("OBJExporter:\n\nYES\t=\tSelection Only...\nNO\t=\tEverything Active/Visible...\n", MB_YESNO)==6
                @use_sel = true
            else
                @use_sel = false
            end
        else
            @use_sel = false
        end

        ### PNG?
        UI.beep
        if UI.messagebox("OBJExporter:\n\nConvert ALL Texture Files to PNG ?\n", MB_YESNO, "") == 6 ### 6=YES
          @png = true
        else
          @png = false
        end

        @base_name = self.fix_name(File.basename(result, ".*"))
        @project_path = File.dirname(result)

        @all_mats = [nil] ### for 'default'
        @mats = []

        saved_names = []
        @model.materials.to_a.each do | mat |
          mat_name = self.fix_name(mat.display_name)
          saved_name = File.basename(mat_name)
          saved_name_uniq = self.make_name_unique(saved_names, saved_name)
          saved_names << saved_name_uniq
          @mats << [mat, saved_name_uniq]
          @all_mats << mat
        end

        self.export()
    end

    def fix_name(name)
        return name.gsub(/[^0-9A-Za-z_-]/, "_")
    end

    def export()
        @obj_name = @base_name + ".obj"

        @obj_filepath = File.join(@project_path, @obj_name)
        @mtllib = @base_name + ".mtl"
        @mtl_file = File.join(@project_path, @mtllib)
        @textures_name = @base_name + "_Textures"
        @textures_path = File.join(@project_path, @textures_name)
        @used_vs = {}
        @used_vts = {}
        @used_vns = {}
        @used_materials = []

        puts(@msg)
        puts(@obj_filepath.tr("\\","/"))

        start_time = Time.now.to_f
        self.export_start()
        end_time = (((Time.now.to_f - start_time)*10000).to_i/10000.0).to_f.to_s

        UI.beep
        puts("OBJexporter: Completed in #{end_time} seconds")
        ###
    end
    
    def export_start()
        @model.start_operation("OBJExporter") ###############################

        if @use_sel
            ents = @sel.to_a
        else
            #while @model.active_entities != @model.entities
              #@model.close_active
            #end
            ents = @model.active_entities.to_a
        end

        @obj_file = File.new(@obj_filepath, "w")
        @obj_file.puts("# Alias Wavefront OBJ File Exported from SketchUp")
        @obj_file.puts("# https://github.com/marrony/sketchup-unreal-objexporter")
        @obj_file.puts("# Units = centimeters")
        @obj_file.puts
        @obj_file.puts("mtllib #{@mtllib}")
        @obj_file.puts
        self.export_obj(ents)
        @obj_file.puts("#EOF")
        @obj_file.flush
        @obj_file.close

        self.export_textures()
        self.export_mtl_material()

        @model.abort_operation
    end

    def log(tag, msg)
        puts(tag.to_s + ': ' + msg.to_s)
    end

    def export_obj(ents)
        entities = ents.find_all do | entity |
            next unless entity.valid?

            entity.class == Sketchup::Group or entity.class == Sketchup::ComponentInstance
        end

        entities = entities.find_all do | entity |
            not entity.hidden? and entity.layer.visible?
        end

        definitions = entities.map do | entity |
            entity.definition
        end

        ot = Geom::Transformation.new()

        definitions.uniq.each do | d |
            objname = @title + "-" + d.name

            self.open_group(objname)
            self.export_component_definition(d, ot)
            self.close_group()
        end
    end
    
    def flattenUVQ(uvq) ### Get UV coordinates from UVQ matrix.
      return Geom::Point3d.new(uvq.x / uvq.z, uvq.y / uvq.z, 1.0)
    end

    def export_group(gp, tr = nil, defmat = nil)
#         gp.make_unique if gp.entities.parent.instances[1]

        log('Group 1', defmat.to_s)
        log('Group 2', gp.material.to_s)
        log('Group 3', gp.definition.material.to_s)

        gp.locked = false
        tc = gp.transformation

        defmat = gp.material if gp.material != nil

        self.export_component_definition(gp.definition, tc, tr, defmat)
    end
     
    def export_component_instance(ci, tr = nil, defmat = nil)
        ci.locked = false
        tc = ci.transformation

        defmat = ci.material if ci.material != nil

        self.export_component_definition(ci.definition, tc, tr, defmat)
    end

    def export_component_definition(definition, tc, tr = nil, defmat = nil)
        tca = tc.to_a

        log('Transformation 1', tca.to_s)
        log('Transformation 2', tr.to_a.to_s) if tr != nil

        if tca[0].to_s == "-0.0"
          tca[0] = -0.000000001
        end

        if tca[5].to_s == "-0.0"
          tca[5] = -0.000000001
        end

        if tca[10].to_s == "-0.0"
          tca[10] = -0.000000001
        end

        tc = Geom::Transformation.new(tca)

        ot = tc
        ot = tr*tc if tr != nil
        sx = ot.to_a[0]
        sy = ot.to_a[5]
        sz = ot.to_a[10]

        #is flipped=true when a component is negative?
        if sx>0 and sy>0 and sz>0
          flipped = false
        elsif sx<0 and sy<0 and sz<0
          flipped = true
        elsif sx<0 and sy>=0 and sz>0
          flipped = true
        elsif sx<0 and sy>0 and sz>=0
          flipped = true
        elsif sx>=0 and sy<0 and sz>0
          flipped = true
        elsif sx>0 and sy<0 and sz>=0
          flipped = true
        elsif sx>=0 and sy>0 and sz<0
          flipped = true
        elsif sx>0 and sy>=0 and sz<0
          flipped = true
        else
          flipped = false
        end

        #todo(marrony): looks like flipped is true when scale is negative, maybe remove this
        if flipped
          log('Export', 'Flipped=True')

          texture_writer = Sketchup.create_texture_writer

          if definition.instances[1]
            log('Make Unique', ci.to_s)
          end

#           definition.parent.make_unique if definition.instances[1]

          faces = definition.entities.find_all do | e |
            e.class == Sketchup::Face
          end

          faces.each do | face |
              log('Faces', face.vertices.to_s)
              log('Faces', face.material)
              log('Faces', face.back_material)

              #fixme(marrony): this code is not correct
              if not face.material or face.material.texture == nil
                face.back_material = face.material
                face.reverse!
              else
                samples = []
                samples << face.vertices[0].position             ### 0,0 | Origin
                samples << samples[0].offset(face.normal.axes.x) ### 1,0 | Offset Origin in X
                samples << samples[0].offset(face.normal.axes.y) ### 0,1 | Offset Origin in Y
                samples << samples[1].offset(face.normal.axes.y) ### 1,1 | Offset X in Y

                xyz = []
                uv  = [] ### Arrays containing 3D and UV points.
                uvh = face.get_UVHelper(true, true, texture_writer)
                samples.each do | position |
                  xyz << position ### XYZ 3D coordinates
                  uvq = uvh.get_front_UVQ(position) ### UV 2D coordinates
                  uv << self.flattenUVQ(uvq)
                end

                pts = [] ### Position texture.

                (0..3).each do |i|
                   pts << xyz[i]
                   pts << uv[i]
                end

                mat = face.material
                face.position_material(mat, pts, false)
                face.reverse!
                face.position_material(mat, pts, true)
              end
          end
        end

        defmat = definition.material if definition.material
        @used_materials << defmat

        self.export_entities(definition.entities, ot, defmat)
    end

    def export_entities(entities, ot, defmat = nil)
        faces = entities.find_all { | e | e.class == Sketchup::Face }
        if faces.length > 0
            self.export_faces(entities.parent, faces, ot, defmat)
        end

        groups = entities.find_all { | e | e.class == Sketchup::Group }
        if groups.length > 0
            groups.each { | g | self.export_group(g, ot, defmat) }
        end

        instances = entities.find_all { | e | e.class == Sketchup::ComponentInstance }
        if instances.length > 0
            instances.each { | i | self.export_component_instance(i, ot, defmat) }
        end
    end

    def open_group(objname)
        @obj_file.puts("g #{objname}")
    end

    def close_group()
        @obj_file.flush()
    end

    def export_faces(parent, all_faces=[], tr=nil, defmat=nil)
        tr = Geom::Transformation.new() if tr == nil

        faces_grouped = all_faces.group_by do | f |
            f.material
        end

        faces_grouped.each do | mat, faces |
            @used_materials << mat

            vs = []
            nos = []
            uvs = []
            meshes = []

            kPoints = 0
            kUVQFront = 1
            kUVQBack = 2
            kNormals = 4

            faces.each do | face |
                next if face.hidden? or not face.layer.visible?

                if self.distorted?(face, tr)
                    log('Distorted', parent.name.to_s)
                    next
                end

                mesh = face.mesh(kPoints | kUVQFront | kNormals)
                next if not mesh

                f_uvs = (1..mesh.count_points).map { | i | mesh.uv_at(i, true) } ####1=front
                f_vs = (1..mesh.count_points).map { | i | mesh.point_at(i) }
                f_nos = (1..mesh.count_points).map { | i | mesh.normal_at(i) }

                f_vcount = 1; f_vcount = vs.length + 1 if vs[0]

                polygons = mesh.polygons.map do | p |
                    indexes = p.map { | px | (f_vs.index(mesh.points[(px.abs-1)]) + f_vcount) }
                    #todo(marrony): fix the array of array
                    [ indexes ]
                end

                meshes.concat(polygons)

                if f_vs
                  vs.concat(f_vs)
                end

                if f_uvs
                  uvs.concat(f_uvs)
                end

                if f_nos
                  nos.concat(f_nos)
                end
            end

#             defn = faces[0].parent
#
#             if not mat
#               mat = defmat
#               if defn != @model and defmat and defmat.texture
#                 #todo(marrony): Understand what this code is doing
#
#                 log('Export Faces', 'Remap?')
#
#                 ### re-map - it's on an Instance/Group
#                 tgp = @model.active_entities.add_group()### we make exploded copy of it and map textures...
#                 tents = tgp.entities
#                 inst = tents.add_instance(defn, Geom::Transformation.new())
#                 inst.explode
#                 tents.to_a.each { | e | e.erase! if e.class == Sketchup::Face and e.material }
#                 tents.to_a.each { | e | e.material = mat if e.class == Sketchup::Face}
#                 self.export_faces(parent, tents.find_all { | e | e.class == Sketchup::Face }, tr, nil)
#                 tgp.erase!
#               else
#                 self.export_obj_file(meshes, uvs, nos, vs, tr, mat)
#               end
#             else

              mat = defmat if not mat

              self.export_obj_file(meshes, uvs, nos, vs, tr, mat)
#             end
        end
    end
      
    def distorted?(face=nil, tr=nil) ### check for distortion
        return false if not face

        mat = face.material
        return false if not mat

        texture = mat.texture
        return false if not texture

        mesh = face.mesh(5) ###7=backs too
        f_uvs = (1..mesh.count_points).map do | i |
            mesh.uv_at(i, true)
        end

        return f_uvs.any? do | uvq |
            (uvq.z.to_f * 1000).round != 1000
        end
    end

    def export_obj_file(meshes=[], uvs=[], nos=[], vs=[], tr=nil, mat=nil)
        return if not meshes

        mat_name = self.find_material_name(mat)

        tr = Geom::Transformation.new() if tr == nil

        if meshes.length != 0 and vs.length != 0
            @obj_file.puts("usemtl #{mat_name}")

            kv = []
            kvt = []
            kvn = []

            vs.each do | v |
                v = tr * v
                xx = v.x
                yy = v.y
                zz = v.z

                xx = 0 if xx == -0
                yy = 0 if yy == -0
                zz = 0 if zz == -0
                newv = "v #{"%.12g" % (xx.to_cm.to_f)} #{"%.12g" % (yy.to_cm.to_f)} #{"%.12g" % (zz.to_cm.to_f)}"
                i = @used_vs.length

                # todo(marrony): fix @used_vs to be a hash of 3d points, not string
                unless @used_vs[newv]
                    @used_vs[newv] = i+1
                    @obj_file.puts(newv)
                end

                kv << @used_vs[newv]
            end

            uvs.each do | uv |
                newvt = "vt #{"%.12g" % (uv.x)} #{"%.12g" % (uv.y)}"
                i = @used_vts.length

                unless @used_vts[newvt]
                    @used_vts[newvt] = i+1
                    @obj_file.puts(newvt)
                end

                kvt << @used_vts[newvt]
            end

            nos.each do | vnor |
                #fixme(marrony): do the correct normal transformation
                nor = tr * vnor
                nor.normalize!

                xx = nor.x
                yy = nor.y
                zz = nor.z

                xx = 0 if xx == -0
                yy = 0 if yy == -0
                zz = 0 if zz == -0
                newvn = "vn #{"%.12g" % (xx)} #{"%.12g" % (yy)} #{"%.12g" % (zz)}"
                i = @used_vns.length

                unless @used_vns[newvn]
                    @used_vns[newvn] = i+1
                    @obj_file.puts(newvn)
                end

                kvn << @used_vns[newvn]
            end

            meshes.each do | mesh |
                f_str = "f"
                mesh.each do | pg |
                    pg.each do | i |
                        kvv = kv[i-1]
                        kvtt = kvt[i-1]
                        kvnn = kvn[i-1]
                        f_str << " #{kvv}/#{kvtt}/#{kvnn}"
                    end

                    @obj_file.puts(f_str)
                end
            end

            @obj_file.puts
        end
    end

    def make_texture_folder()
        begin
          Dir.mkdir(@textures_path) if not File.exist?(@textures_path)
        rescue
          UI.messagebox(@textures_path + " ??")
        end
    end
    
    def export_textures()
        txtr = @used_materials.compact.uniq.any? do | mat |
            mat.texture != nil
        end

        return unless txtr

        self.make_texture_folder()
        temp_group = @model.active_entities.add_group()
        tw = Sketchup.create_texture_writer

        @all_mats.each do | mat |
            next if not mat
            next if not @used_materials.include?(mat)
            if mat.texture 
                temp_group.material = mat
                mat_texture_file = mat.texture.filename.tr("\\", "/")

                if @png
                  texture_extn = '.PNG'
                else
                  texture_extn = File.extname(mat_texture_file)
                  texture_extn = '.PNG' if texture_extn.empty?
                  itypes = ['.png','.jpg','.bmp','.tif','.psd','.tga']
                  texture_extn = '.PNG' unless itypes.include?(texture_extn.downcase)
                end

                mat_name = ""
                @mats.each do | ar |
                    if ar[0] == mat
                        mat_name = ar[1]
                        break
                    end
                end

                mat_texture_name = mat_name + texture_extn
                tpath = File.join(@textures_path, mat_texture_name)
                tw.load(temp_group)
                tw.write(temp_group, tpath)
            end
        end

        temp_group.erase! if temp_group.valid?
    end

    def find_material_name(mat)
        mat_name = @mats.find do | ar |
            ar[0] == mat
        end

        return "Default_Material" if not mat_name

        return mat_name[1]
    end

    def export_mtl_material()
        ffcol = @model.rendering_options["FaceFrontColor"]

        mtl_file = File.new(@mtl_file,"w")
        mtl_file.puts("# Alias Wavefront MTL File Exported from SketchUp")
        mtl_file.puts("# https://github.com/marrony/sketchup-unreal-objexporter")
        mtl_file.puts("# Made for '"+@obj_name+"'")
        mtl_file.puts
        mtl_file.puts("newmtl Default_Material")
        mtl_file.puts("Ka " + ffcol.to_a[0..2].collect{|c| "%.6g" % ((c.to_f/255)) }.join(" "))
        mtl_file.puts("Kd " + ffcol.to_a[0..2].collect{|c| "%.6g" % ((c.to_f/255)) }.join(" "))
        mtl_file.puts("Ks 0.333 0.333 0.333")
        mtl_file.puts("Ns 0")
        mtl_file.puts("d 1")
        mtl_file.puts("Tr 1")
        mtl_file.puts

        @used_materials.uniq!
        @used_materials.each do | mat |
            next if not mat

            matname = self.find_material_name(mat)

            if mat and mat.texture
                if @png
                  texture_extn='.PNG'
                else
                  texture_extn=File.extname(mat.texture.filename)
                  texture_extn='.PNG' if texture_extn.empty?
                  itypes=['.png','.jpg','.bmp','.tif','.psd','.tga']
                  texture_extn='.PNG' unless itypes.include?(texture_extn.downcase)
                end

                texture_path = File.join(@textures_name, matname + texture_extn)
            end

            self.append_mtl(mtl_file, mat, matname, texture_path)
        end

        mtl_file.puts("#EOF")
        mtl_file.flush
        mtl_file.close
    end

    def append_mtl(mtl_file, mat, matname, texture_path)
       mtl_file.puts("newmtl #{matname}")

       if not mat.use_alpha?
           mtl_file.puts("Ka " + mat.color.to_a[0..2].collect{|c| "%.6g" % ((c.to_f/255)) }.join(" "))
           mtl_file.puts("Kd " + mat.color.to_a[0..2].collect{|c| "%.6g" % ((c.to_f/255)) }.join(" "))
           mtl_file.puts("Ks 0.333 0.333 0.333")
           mtl_file.puts("Ns 0")
           mtl_file.puts("d 1")
           mtl_file.puts("Tr 1")
           mtl_file.puts("map_Kd #{texture_path}") if texture_path
       else ### it's transparent
           mtl_file.puts("Ka " + mat.color.to_a[0..2].collect{|c| "%.6g" % ((c.to_f/255)) }.join(" "))
           mtl_file.puts("Kd " + mat.color.to_a[0..2].collect{|c| "%.6g" % ((c.to_f/255)) }.join(" "))
           mtl_file.puts("Ks 0.333 0.333 0.333")
           mtl_file.puts("Ns 0")
           mtl_file.puts("d #{"%.3g" % mat.alpha }")
           mtl_file.puts("Tr #{"%.3g" % mat.alpha }")
           mtl_file.puts("map_Kd #{texture_path}") if texture_path
       end

       mtl_file.puts
    end

    def export_distorted_texture(face, texture_path)
        tpath = File.join(@project_path, texture_path)
        tw = Sketchup.create_texture_writer
        tw.load(face, true)
        tw.write(face, true, tpath)
    end
    
    def make_name_unique(saved_names=[], saved_name="")
        if saved_names.include?(saved_name)
            counter = 1
            while counter < 10000
                new_name = File.basename(saved_name, ".*") + counter.to_s + File.extname(saved_name)
                return new_name if not saved_names.include?(new_name)
                counter += 1
            end
        end
        return saved_name
    end
############## end of exporter code #########################

end

